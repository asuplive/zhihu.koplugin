--[[
    Zhihu Reader Plugin for KOReader v153
    - QR code login: auto-completing poll login
    - Risk-control (unhuman) verification flow for blocked networks (Android)
    - Recommended feed (12 items per batch) with Load More cursor
    - ArticleViewer with ScrollHtmlWidget for reading (native page turn)
    - All article images load, auto-downscaled to screen width (e-ink safe)
    - Per-article image cache: each image is downloaded once, stored in
      zhihu_article_images/<id>/ and shown instantly on the next visit
    - Download progress in a bottom status line, refreshed on page turns only
    - Mixed text and image display (图文混排)
    - v150: pictures are sized to the text column (not the raw screen) and
      centred as inline content, so they no longer lean to the right
    - v151: optional answerer avatar next to each author name (off by default)
    - v153: every settings label is bilingual (Chinese / English)
- v152: that avatar is sized 4x the body font (~88px at font 22), still
      capped at 14% of the screen so it never crowds the author line
    - Export to HTML & EPUB with auto-open

    v140 (paging / speed / font):
    - Answers are fetched and rendered 5 at a time. The page ends with a
      "下一个" button; tapping it (or the bottom bar) loads the next 5.
    - Answer HTML is stripped down to what MuPDF can actually render before
      layout, which is what makes long answers stop lagging on page turns.
    - Fetched pages are cached on disk for one hour, so flipping back and
      forth between batches is instant.
    - New "Font Family" setting (presets + custom family name).
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local Menu            = require("ui/widget/menu")
local TextViewer      = require("ui/widget/textviewer")
local Font            = require("ui/font")
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local NetworkMgr      = require("ui/network/manager")
local _               = require("gettext")
local T               = require("ffi/util").template
local Device          = require("device")
local Screen          = Device.screen
local logger          = require("logger")

-- QR login: Trapper + ImageViewer (v7 proven stable on Android)
local Trapper       = require("ui/trapper")
local ImageViewer   = require("ui/widget/imageviewer")
local RenderImage   = require("ui/renderimage")

local ZhihuClient  = require("zhihu_client")
local ArticleViewer = require("article_viewer")

-- Safely quote a path for os.execute (prevents breakage/injection on quotes & spaces)
local function shellQuote(p)
    return "'" .. tostring(p):gsub("'", "'\\''") .. "'"
end

-- v127: Truncate a string to max_len bytes without splitting a UTF-8 character
-- (avoids mojibake when cutting Chinese text in list entries / loading titles)
local function utf8Truncate(s, max_len)
    if not s or #s <= max_len then return s end
    local cut = max_len
    -- Step back over UTF-8 continuation bytes (10xxxxxx) to a character boundary
    while cut > 1 do
        local b = s:byte(cut)
        if b and b >= 0x80 and b < 0xC0 then
            cut = cut - 1
        else
            break
        end
    end
    return s:sub(1, cut)
end

local DEFAULT_FONT_SIZE = 22
-- v152: avatar side = body font size x scale (3=small, 4=large, 5=xlarge)
local DEFAULT_AVATAR_SCALE = 4
-- v151: show the answerer's avatar next to the name in front of each answer.
-- Off by default: it costs one extra request per new author and the reader
-- who only wants text should never pay for it.
local DEFAULT_SHOW_AVATAR = false
-- v146: paragraphs are indented by this many characters by default (2 = the
-- classic Chinese first-line indent; 0 = flush left).
local DEFAULT_PARA_INDENT = 2
-- v148: give a content picture a page of its own (page break before/after),
-- so a small picture is not squeezed into the leftover height of a text page.
local DEFAULT_IMAGE_PAGE_BREAK = false
local QR_POLL_INTERVAL = 3
local QR_MAX_POLLS = 40

-- v140: answers per page (fetch + render unit).
local DEFAULT_PAGE_SIZE = 5
-- v140: an answer page stays cached on disk for this long (seconds).
local DEFAULT_CACHE_TTL = 3600

-- v130: ALL images are loaded (the v129 count/size caps were removed per
-- user requirement). Freeze protection now comes from downscaling instead:
-- article_viewer.lua shrinks every image wider than the screen to a
-- screen-width PNG before rendering, so an image-heavy article costs
-- bounded memory per image instead of tens of MB per full-res photo.
-- Downloads also show visible progress (i/N), refreshed on page turns only.
--
-- v132: images are cached per article under
--   <data dir>/zhihu_article_images/<question or article id>/
-- Every image is fetched exactly ONCE; later visits render the stored file
-- immediately. Only a cached file larger than this (extremely rare) is
-- dropped and re-fetched, because decoding it raw could stall the device.
local CACHE_RENDER_LIMIT = 8 * 1024 * 1024 -- 8 MB

-- v140: Font Family setting --------------------------------------------------
-- The value stored in settings is a CSS font-family NAME (not a file path):
-- MuPDF resolves it against the fonts the device actually provides.
local DEFAULT_CJK_FONT_STACK = '"Noto Serif CJK SC", "WenQuanYi Micro Hei", "Droid Sans Fallback", serif'

-- Family names that are commonly present on e-ink readers, Android and
-- desktop, plus the generic CSS families.
local FONT_PRESETS = {
    "Noto Serif CJK SC",
    "Noto Sans CJK SC",
    "Source Han Serif SC",
    "Source Han Sans SC",
    "Noto Serif",
    "Noto Sans",
    "Droid Sans Fallback",
    "WenQuanYi Micro Hei",
    "WenQuanYi Zen Hei",
    "Songti SC",
    "STSong",
    "STKaiti",
    "Heiti SC",
    "STHeiti",
    "SimSun",
    "SimHei",
    "KaiTi",
    "Microsoft YaHei",
    "PingFang SC",
    "serif",
    "sans-serif",
    "monospace",
}

-- Turn a stored font name into a CSS font-family token. Generic families must
-- stay bare ("serif"), everything else is quoted.
local function cssFontFamily(name)
    if not name or name == "" then return nil end
    local n = name:gsub("^%s+", ""):gsub("%s+$", "")
    if n == "" then return nil end
    local generic = { serif = true, ["sans-serif"] = true, monospace = true,
                      cursive = true, fantasy = true }
    if generic[n:lower()] then
        return n:lower()
    end
    return '"' .. n:gsub('"', "") .. '"'
end

-- CSS for ScrollHtmlWidget article rendering
-- __FONT_FAMILY__ is substituted by buildArticleCss().
local ARTICLE_CSS_TEMPLATE = [[
html, body {
    font-family: __FONT_FAMILY__;
    line-height: 1.8;
    color: #000;
    margin: 0;
    padding: 0;
}
a {
    color: #000;
    text-decoration: none;
}
/* v141: the old 33%-wide / 180px-tall box looked like a broken thumbnail and
   was easily mistaken for a picture that renders too small. */
.img-placeholder {
    display: block;
    width: 86%;
    border: 2px dashed #888;
    text-align: center;
    padding: 16px 0;
    margin: 12px auto;
}
.img-num {
    font-size: 1.2em;
    color: #555;
}
.omitted {
    color: #666;
    font-style: italic;
}
.close-link {
    float: right;
    font-weight: bold;
}

.title {
    text-align: left;
    border-bottom: 2px solid #000;
    padding-bottom: 5px;
    margin-bottom: 8px;
    margin-top: 0;
}
h1.title {
    font-size: 1.6em;
    font-weight: bold;
}
h2.author {
    font-size: 1.3em;
    font-weight: bold;
    font-style: italic;
    margin-bottom: 2px;
}
.answer {
    margin-bottom: 12px;
    padding-bottom: 8px;
    border-bottom: 1px dashed #888;
    margin-top: 0;
}
.voteup {
    color: #666;
    margin-bottom: 6px;
    font-style: italic;
}
p {
    /* v146: __PARA_INDENT__ is substituted by buildArticleCss(): the reader can
       pick "no indent" (flush left) or the classic two-character indent. */
    text-indent: __PARA_INDENT__;
    margin: 0 0 4px 0;
}
img {
    max-width: 100%;
    height: auto;
    /* v150: pictures stay inline. A block image ignores text-align, so the
       centred container had no effect and every picture hugged the left edge
       of the column (with an over-wide one spilling past the right margin).
       Inline is also what makes the container's text-align: center work. */
    display: inline;
    margin: 0;
}
/* v151: the answerer's avatar. It sits inside the author heading, so its size
   is tied to the heading's font size instead of the picture it came from, and
   it is pushed down a touch so it lines up with the name rather than the
   baseline of the text. */
img.avatar {
    /* v151/v152: the pixel size is carried by the width/height attributes
       (crengine honours those, it does not resolve em on images); this rule
       only keeps the picture on the author's line and off the column edges. */
    max-width: 30%;
    height: auto;
    vertical-align: middle;
    margin: 0 0.4em 0 0;
}
/* v141: crengine ignores width: 100% on <img>, so content pictures carry an
   explicit pixel width attribute instead (see zhihu_client.getRenderImgWidth).
   Emoji / stickers keep their intrinsic size. */
img.full-img {
    max-width: 100%;
    /* v150: an inline picture obeys the parent block's text-align. The global
       `img { display: block }` above is exactly what made v149's centring a
       no-op: a block box ignores text-align, so the picture just sat on the
       left edge of its block and an over-wide one spilled past the right
       margin -- which reads as "still pushed to the right". */
    display: inline;
    margin: 0;
    vertical-align: middle;
}
/* v150: a picture is wrapped in its own full-width block so text-align can
   centre it. text-indent: 0 cancels the paragraph indent (2 characters) that
   the picture's line box used to inherit and made everything drift right. */
div.img-block {
    text-align: center;
    text-indent: 0;
    margin: 0.8em 0;
    padding: 0;
    width: 100%;
}
div.page-img {
    /* v148: give the picture a page of its own (crengine honours page-break on
       a block box; an inline img is not reliable there). */
    page-break-before: always;
    page-break-after: always;
    text-align: center;
    text-indent: 0;
    margin: 10px 0;
    width: 100%;
}
img.tiny-img {
    display: inline;
    margin: 2px 3px;
}
blockquote {
    border-left: 3px solid #888;
    padding-left: 15px;
    margin: 10px 0;
}
li {
    margin-bottom: 8px;
}
code {
    font-family: monospace;
}
pre {
    padding: 10px;
    border: 1px solid #888;
    overflow-x: auto;
}
h2, h3 {
    font-weight: bold;
    margin: 15px 0 10px 0;
}

/* v140: end-of-page navigation (next batch / previous batch) */
.page-nav {
    margin-top: 24px;
    padding-top: 12px;
    border-top: 2px solid #000;
}
.nav-hint {
    text-align: center;
    color: #444;
    font-style: italic;
    text-indent: 0;
    margin: 12px 0;
}
.nav-btn {
    text-align: center;
    margin: 16px 0;
    border: 2px solid #000;
    padding: 12px 0;
}
.nav-btn a {
    /* v140: block level, so the whole framed box is tappable (an inline link
       would only react on the text glyphs, which is painful on e-ink). */
    display: block;
    padding: 4px 0;
    font-weight: bold;
    text-decoration: underline;
}
.nav-btn-small {
    text-align: center;
    margin: 10px 0;
}
.nav-btn-small a {
    color: #555;
}
]]

-- Build the article stylesheet with the chosen font family on top of the
-- built-in CJK stack (so an unresolvable name never blanks out Chinese text).
-- v146: para_indent is the first-line indent of a paragraph, in characters:
-- 0 = flush left, 2 = the classic two-character indent.
local function buildArticleCss(font_name, para_indent)
    local family = DEFAULT_CJK_FONT_STACK
    local chosen = cssFontFamily(font_name)
    if chosen then
        family = chosen .. ", " .. DEFAULT_CJK_FONT_STACK
    end
    local indent = "2em"
    if para_indent == 0 then indent = "0" end
    local css = ARTICLE_CSS_TEMPLATE:gsub("__FONT_FAMILY__", function() return family end)
    css = css:gsub("__PARA_INDENT__", function() return indent end)
    return css
end

-- =========================================================================
-- Plugin Module
-- =========================================================================

local Zhihu = WidgetContainer:extend{
    name = "zhihu",
    is_doc_only = false,
}

function Zhihu:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/zhihu_settings.lua"
    self.settings = LuaSettings:open(self.settings_file)
    self.updated = false
    self.cached_user_name = nil
    self.pending_token = nil
    self._qr_viewer = nil
    self._menu_widget = nil
    self._login_poll_timer = nil
    self._login_poll_token = nil
    self.client = ZhihuClient:new()
    self.client:init(DataStorage:getSettingsDir())
    -- v140: on-disk cache for fetched answer pages
    self.page_cache_dir = DataStorage:getDataDir() .. "/zhihu_pages/"
    self.client:setCacheDir(self.page_cache_dir)
    self.client:setCacheTTL(DEFAULT_CACHE_TTL)
    os.execute("mkdir -p " .. shellQuote(self.page_cache_dir))
    self.qr_image_path = DataStorage:getDataDir() .. "/cache/zhihu_qrcode.png"
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function Zhihu:onFlushSettings()
    if self.updated then
        self.settings:flush()
        self.updated = nil
    end
    self.client:saveCookies()
end

-- =========================================================================
-- Main Menu
-- =========================================================================

function Zhihu:addToMainMenu(menu_items)
    local plugin = self
    menu_items.zhihu_reader = {
        text = _("知乎阅读器 (Zhihu Reader)"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return plugin:buildMenuItems()
        end,
    }
end

function Zhihu:buildMenuItems()
    local sub_items = {}
    local logged_in = self.client:isLoggedIn()

    if logged_in then
        local user_name = self.cached_user_name
        if not user_name then
            user_name = self.client:getUserName()
            self.cached_user_name = user_name
        end
        if user_name and user_name ~= "" then
            table.insert(sub_items, {text = _("用户 (User): ") .. user_name, enabled = false})
        end
        table.insert(sub_items, {
            text = _("推荐流 (Recommended Feed)"),
            callback = function() self:showRecommendFeed() end,
        })
        table.insert(sub_items, {
            text = _("退出登录 (Logout)"),
            callback = function() self:doLogout() end,
        })
    else
        table.insert(sub_items, {
            text = _("扫码登录 (Login with QR Code)"),
            callback = function() self:startQrLogin() end,
        })
    end

    table.insert(sub_items, {
        text = "Font Size",
        sub_item_table = {
            {text = _("小 (Small 18)"),  checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 18 end,
             callback = function() self.settings:saveSetting("font_size", 18) self.updated = true end},
            {text = _("中 (Medium 22)"), checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 22 end,
             callback = function() self.settings:saveSetting("font_size", 22) self.updated = true end},
            {text = _("大 (Large 26)"),  checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 26 end,
             callback = function() self.settings:saveSetting("font_size", 26) self.updated = true end},
            {text = _("特大 (Extra Large 30)"), checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 30 end,
             callback = function() self.settings:saveSetting("font_size", 30) self.updated = true end},
        },
    })

    table.insert(sub_items, {
        text = _("段落首行缩进 (Paragraph Indent)"),
        sub_item_table = {
            {text = _("不缩进（贴最左）/ No Indent"),
             checked_func = function() return self:getParaIndent() == 0 end,
             callback = function()
                 self.settings:saveSetting("para_indent", 0)
                 self.updated = true
             end},
            {text = _("缩进两个汉字 / Indent 2 Chars"),
             checked_func = function() return self:getParaIndent() == DEFAULT_PARA_INDENT end,
             callback = function()
                 self.settings:saveSetting("para_indent", DEFAULT_PARA_INDENT)
                 self.updated = true
             end},
        },
    })

    table.insert(sub_items, {
        text = _("图片排版 (Picture Layout)"),
        sub_item_table = {
            {text = _("图片与上下文字留白（默认）/ Margin (Default)"),
             checked_func = function() return not self:getImagePageBreak() end,
             callback = function()
                 self.settings:saveSetting("image_page_break", false)
                 self.updated = true
             end},
            {text = _("图片单独占一页（另起页显示）/ Own Page"),
             checked_func = function() return self:getImagePageBreak() end,
             callback = function()
                 self.settings:saveSetting("image_page_break", true)
                 self.updated = true
             end},
        },
    })

    table.insert(sub_items, {
        text = _("显示回答问题人头像 (Answerer Avatar)"),
        checked_func = function() return self:getShowAvatar() end,
        callback = function()
            local current = self:getShowAvatar()
            self.settings:saveSetting("show_avatar", not current)
            self.updated = true
            UIManager:show(InfoMessage:new{
                text = T(_("Answerer avatar: %1"), not current and _("On") or _("Off")),
                timeout = 2,
            })
        end,
    })

    table.insert(sub_items, {
        text = _("头像大小 (Avatar Size)"),
        sub_item_table = {
            {text = _("小（正文 3 倍）/ Small (3x)"),
             checked_func = function() return self:getAvatarScale() == 3 end,
             callback = function() self.settings:saveSetting("avatar_scale", 3) self.updated = true end},
            {text = _("大（正文 4 倍，默认）/ Large (4x, Default)"),
             checked_func = function() return self:getAvatarScale() == DEFAULT_AVATAR_SCALE end,
             callback = function() self.settings:saveSetting("avatar_scale", DEFAULT_AVATAR_SCALE) self.updated = true end},
            {text = _("超大（正文 5 倍）/ Extra Large (5x)"),
             checked_func = function() return self:getAvatarScale() == 5 end,
             callback = function() self.settings:saveSetting("avatar_scale", 5) self.updated = true end},
        },
    })

    table.insert(sub_items, {
        text = _("字体设置 (Font Family)"),
        sub_item_table_func = function() return self:buildFontMenu() end,
    })

    table.insert(sub_items, {
        text = _("显示图片 (Show Images)"),
        checked_func = function() return self.settings:readSetting("show_images", false) end,
        callback = function()
            local current = self.settings:readSetting("show_images", false)
            self.settings:saveSetting("show_images", not current)
            self.updated = true
            UIManager:show(InfoMessage:new{
                text = T(_("Show images: %1"), not current and _("On") or _("Off")),
                timeout = 2,
            })
        end,
    })

    table.insert(sub_items, {
        text = _("查看图片 (View Images)"),
        enabled_func = function()
            return self.current_article ~= nil
                and self.current_article.image_list
                and #self.current_article.image_list > 0
        end,
        callback = function() self:showImages() end,
    })

    table.insert(sub_items, {
        text = _("清除图片缓存 (Clear Image Cache)"),
        callback = function() self:clearCache() end,
    })

    table.insert(sub_items, {
        text = _("清除页面缓存 (Clear Page Cache)"),
        callback = function() self:clearPageCache() end,
    })

    table.insert(sub_items, {
        text = _("导出 HTML (Export HTML)"),
        enabled_func = function()
            return self.current_article ~= nil
        end,
        callback = function() self:exportHtml() end,
    })

    table.insert(sub_items, {
        text = _("导出 EPUB (Export EPUB)"),
        enabled_func = function()
            return self.current_article ~= nil
        end,
        callback = function() self:exportEpub() end,
    })

    table.insert(sub_items, {
        text = _("关于 (About)"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Zhihu Reader v140\n\n- QR code login (auto-complete)\n- Risk-control verification flow (browser)\n- Recommended feed: 12 items per batch\n- Answers: 5 per page, 'Next' button for more\n- Lightweight HTML for smooth page turns\n- Page cache: 1 hour on disk\n- Font family + font size settings\n- All images load (downscaled to screen)\n- Image cache: download once, reuse\n- Mixed text and images\n- Export to HTML & EPUB (auto-open)"),
                timeout = 5,
            })
        end,
    })

    return sub_items
end

-- =========================================================================
-- QR Login (ImageViewer with QR image, TextViewer fallback)
-- =========================================================================

function Zhihu:startQrLogin()
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{text = _("Device is offline."), timeout = 3})
        return
    end

    -- Stop any previous (stale) polling session before starting a new one.
    self:_stopLoginPoll()

    -- Generate token
    local token = self.client:getQrCodeToken()
    if not token then
        UIManager:show(InfoMessage:new{text = _("Failed to generate QR code."), timeout = 3})
        return
    end

    -- Capture the currently open menu (the Zhihu submenu) so we can refresh it after login.
    self._menu_widget = (UIManager.getTopWidget and pcall(UIManager.getTopWidget) and UIManager:getTopWidget())
        or (UIManager._running_widgets and UIManager._running_widgets[#UIManager._running_widgets])

    local qr_url = self.client:getQrCodeImageUrl(self.client:getScanUrl(token))
    if qr_url then
        local qr_dir = DataStorage:getDataDir() .. "/zhihu_qr/"
        os.execute("mkdir -p " .. shellQuote(qr_dir))
        local qr_path = qr_dir .. "qr.png"
        -- v127 fix: check the actual download result and file existence,
        -- not just whether the call was reached without a Lua error.
        local dl_ok, dl_result = pcall(function()
            return self.client:_downloadImage(qr_url, qr_path)
        end)
        local download_ok = (dl_ok and dl_result == true)
        if download_ok then
            local f = io.open(qr_path, "rb")
            if f then f:close() else download_ok = false end
        end

        if download_ok then
            -- Build HTML to display QR via ScrollHtmlWidget
            local qr_html = "<div style='text-align:center;'><img src='qr.png' style='max-width:80%;'/></div>"
                .. "<p style='text-align:center; font-size:1.2em; margin-top:20px;'>" .. _("Scan with Zhihu App") .. "</p>"
                .. "<p style='text-align:center; font-size:0.9em; color:#555;'>" .. _("Login completes automatically once confirmed") .. "</p>"

            local show_ok = pcall(function()
                local viewer = ArticleViewer:new{
                    html_content = qr_html,
                    css = "body { text-align: center; padding: 20px; }",
                    image_dir = qr_dir,
                    font_size = 22,
                }
                self._qr_viewer = viewer
                UIManager:show(viewer)
            end)

            if show_ok then
                -- Begin auto-polling: detect scan/confirm and finish login on its own.
                self:_startLoginPoll(token)
                return
            end
        end
    end

    -- Fallback: show URL text in TextViewer (auto-polling still runs in the background)
    local scan_url = self.client:getScanUrl(token)
    UIManager:show(TextViewer:new{
        title = _("Login with Zhihu App"),
        text = _("1. Open Zhihu app on your phone\n")
            .. _("2. Tap the scan icon (top-right)\n")
            .. _("3. Scan or enter this URL:\n\n")
            .. scan_url
            .. "\n\n"
            .. _("4. Confirm login on your phone\n")
            .. _("Login completes automatically once confirmed"),
        text_face = Font:getFace("cfont", 20),
        justified = false,
    })
    self:_startLoginPoll(token)
end

-- Poll the QR scan status in the background and finish login automatically.
function Zhihu:_startLoginPoll(token)
    self:_stopLoginPoll()
    self._login_poll_token = token
    local plugin = self
    local function poll()
        if plugin._login_poll_token ~= token then return end
        local ok, status, extra = pcall(function() return plugin.client:checkScanStatus(token) end)
        if not ok then
            -- Transient network error: retry shortly.
            plugin._login_poll_timer = UIManager:scheduleIn(3, poll)
            return
        end
        if status == "confirmed" then
            plugin:_finishLogin(token)
        elseif status == "expired" then
            plugin:_stopLoginPoll()
            UIManager:show(InfoMessage:new{text = _("QR code expired. Please try again."), timeout = 3})
        elseif status == "blocked" then
            -- v128: Zhihu risk control (403 / 40352) — human verification is
            -- required before login polling can continue.
            plugin:_handleRiskControl(token, extra)
        else
            -- "waiting" or "scanned": keep polling.
            plugin._login_poll_timer = UIManager:scheduleIn(2.5, poll)
        end
    end
    self._login_poll_timer = UIManager:scheduleIn(1.5, poll)
end

-- =========================================================================
-- v128: Zhihu Risk Control ("unhuman" verification) handling
--
-- When the current network is flagged (typical on Android phones on mobile
-- data), scan_info returns HTTP 403 with error 40352 and a redirect to a
-- human-verification page. That page is a JavaScript slider captcha which
-- KOReader cannot render, so we:
--   1. Stop polling (instead of silently looping forever — the old "no
--      reaction after scanning" symptom).
--   2. Offer to open the verification URL in the system browser
--      (Device:openLink works on Android), or show it as text.
--   3. Let the user resume polling once the verification is done.
--   4. Offer a restart with fresh cookies (new d_c0 device identity).
-- The verification session is bound to this client's cookies, so completing
-- it in the browser lifts the block for KOReader's own requests.
-- =========================================================================

function Zhihu:_showVerifyUrl(url)
    url = url or self._risk_verify_url
    if not url then
        UIManager:show(InfoMessage:new{
            text = _("No verification URL available.\nTry 'Restart Login (Fresh Cookies)'."),
            timeout = 4,
        })
        return
    end
    UIManager:show(TextViewer:new{
        title = _("Human Verification URL"),
        text = _("Zhihu flagged this network as abnormal\n(risk control, code 40352).\n\nOpen this URL in any browser, finish the\nverification, then come back and tap\n'I Have Verified - Continue Login'.\n\n") .. url,
        text_face = Font:getFace("cfont", 20),
        justified = false,
    })
end

function Zhihu:_handleRiskControl(token, verify_url)
    self:_stopLoginPoll()
    local plugin = self
    self._risk_verify_url = verify_url

    local items = {}
    table.insert(items, {
        text = _("Open Verification in Browser"),
        callback = function()
            local opened = false
            if verify_url and Device.openLink then
                opened = pcall(function() Device:openLink(verify_url) end)
            end
            if opened then
                UIManager:show(InfoMessage:new{
                    text = _("Finish the verification in the browser,\nthen tap 'I Have Verified - Continue Login'."),
                    timeout = 6,
                })
            else
                -- No system-browser bridge (or it failed): fall back to text.
                plugin:_showVerifyUrl(verify_url)
            end
        end,
    })
    table.insert(items, {
        text = _("Show Verification URL"),
        callback = function()
            plugin:_showVerifyUrl(verify_url)
        end,
    })
    table.insert(items, {
        text = _("I Have Verified - Continue Login"),
        callback = function()
            if token then plugin:_startLoginPoll(token) end
        end,
    })
    table.insert(items, {
        text = _("Restart Login (Fresh Cookies)"),
        callback = function()
            -- Drop the risk-flagged d_c0 and get a brand-new device identity.
            pcall(function() plugin.client:resetSession() end)
            plugin:startQrLogin()
        end,
    })
    table.insert(items, {
        text = _("Cancel Login"),
        callback = function()
            if plugin._qr_viewer then
                pcall(function() UIManager:close(plugin._qr_viewer) end)
                plugin._qr_viewer = nil
            end
            if plugin._risk_menu then
                pcall(function() UIManager:close(plugin._risk_menu) end)
                plugin._risk_menu = nil
            end
        end,
    })

    local menu = Menu:new{
        title = _("Zhihu Verification Needed"),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
    }
    function menu:onClose()
        UIManager:close(menu)
        return true
    end
    self._risk_menu = menu
    UIManager:show(menu)
end

function Zhihu:_stopLoginPoll()
    if self._login_poll_timer then
        pcall(function() UIManager:unschedule(self._login_poll_timer) end)
        self._login_poll_timer = nil
    end
    self._login_poll_token = nil
end

function Zhihu:_finishLogin(token)
    self:_stopLoginPoll()
    self.client:saveCookies()
    self.pending_token = nil
    self.cached_user_name = self.client:getUserName()
    -- Close the QR viewer if it is still on screen.
    if self._qr_viewer then
        pcall(function() UIManager:close(self._qr_viewer) end)
        self._qr_viewer = nil
    end
    -- v128: close the risk-control dialog if it is still open.
    if self._risk_menu then
        pcall(function() UIManager:close(self._risk_menu) end)
        self._risk_menu = nil
    end
    self._risk_verify_url = nil
    -- Refresh the open Zhihu submenu so it shows the logged-in items.
    local w = self._menu_widget
    if w and w.updateItems then
        pcall(function() w:updateItems() end)
    end
    self.updated = true
    UIManager:show(InfoMessage:new{text = _("Login successful!"), timeout = 3})
end

function Zhihu:doLogout()
    self:_stopLoginPoll()
    self.client:logout()
    self.pending_token = nil
    self.cached_user_name = nil
    self._qr_viewer = nil
    self._menu_widget = nil
    -- v128: drop risk-control state too
    if self._risk_menu then
        pcall(function() UIManager:close(self._risk_menu) end)
        self._risk_menu = nil
    end
    self._risk_verify_url = nil
    -- v127 fix: drop the recommend-feed cursor so a new account
    -- does not "Load More" from the previous account's position
    self.feed_next_url = nil
    UIManager:show(InfoMessage:new{text = _("Logged out."), timeout = 2})
end

-- =========================================================================
-- Recommended Feed
-- =========================================================================

function Zhihu:showRecommendFeed()
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{text = _("Device is offline."), timeout = 3})
        return
    end
    self:_loadRecommendFeed(nil)
end

-- Shared feed list renderer (used by the Recommended Feed).
-- 'show_more' adds the "Load More" cursor button (recommend only; hot is a fixed snapshot).
function Zhihu:_loadFeedMenu(items, title, show_more)
    local menu_items = {}
    for _, item in ipairs(items) do
        local text = item.title or "No Title"
        if item.author and item.author ~= "" then
            text = text .. "\n  -- " .. item.author
        end
        -- Hot-feed heat / ranking hint
        if item.hot_text and item.hot_text ~= "" then
            text = text .. "\n  " .. item.hot_text
        end
        -- Excerpt snippet (hot feed carries one)
        if item.excerpt and item.excerpt ~= "" then
            local ex = item.excerpt
            -- v127: cut on a UTF-8 boundary instead of raw bytes
            if #ex > 60 then ex = utf8Truncate(ex, 57) .. "..." end
            text = text .. "\n  " .. ex
        end
        -- Image hint if available
        if item.images and #item.images > 0 then
            local img_url = item.images[1]
            if #img_url > 60 then
                img_url = img_url:sub(1, 57) .. "..."
            end
            text = text .. "\n  [图片x" .. #item.images .. "] " .. img_url
        end
        table.insert(menu_items, {
            text = text,
            question_id = item.question_id,
            question_title = item.title,
            item_type = item.item_type or "answer",
            item_content = item.content,
            item_author = item.author,
            item_voteup = item.voteup,
            item_images = item.images or {},
        })
    end

    -- "Load more" button for cursor-based feeds (recommend); hot feed is a fixed snapshot
    if show_more then
        table.insert(menu_items, {
            text = _(">>> Load More >>>"),
            is_refresh = true,
            callback = function() end,  -- Dummy callback, handled in onMenuSelect
        })
    end

    local menu = Menu:new{
        title = title,
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
    }

    local plugin = self
    function menu:onMenuSelect(entry)
        if entry.is_refresh then
            UIManager:close(menu)
            if plugin.feed_next_url then
                plugin:_loadRecommendFeed(plugin.feed_next_url)
            else
                UIManager:show(InfoMessage:new{text = _("No more items."), timeout = 2})
            end
            return
        end

        -- Keep menu open - TextViewer overlays on top
        if entry.question_id then
            plugin:showArticle(entry.question_id, entry.question_title, entry.item_type)
        else
            UIManager:show(InfoMessage:new{text = _("No content."), timeout = 3})
        end
    end

    function menu:onClose()
        UIManager:close(menu)
        return true
    end

    UIManager:show(menu)
end

function Zhihu:_loadRecommendFeed(start_url)
    if not self.client:isLoggedIn() then
        UIManager:show(InfoMessage:new{text = _("Please login first."), timeout = 3})
        return
    end

    local loading = InfoMessage:new{text = _("Loading..."), timeout = 0}
    UIManager:show(loading)

    -- v127: fetch up to 3 pages behind the scenes, but the list is capped
    -- at 12 items (client-side limit); "Load More" continues from the cursor.
    local items, next_url = self.client:getRecommendFeed(start_url, 3)
    UIManager:close(loading)

    if not items then
        local diag = tostring(next_url or "unknown")
        local last_err = self.client:getLastError() or ""
        if last_err ~= "" then diag = diag .. "\n(" .. last_err .. ")" end
        UIManager:show(InfoMessage:new{text = T(_("Load failed: %1"), diag), timeout = 8})
        return
    end

    -- Remember the cursor so "Load More" loads the next batch instead of re-fetching the top.
    self.feed_next_url = next_url
    self:_loadFeedMenu(items, _("推荐流 (Recommended Feed)"), true)
end

-- =========================================================================
-- Read Article (ArticleViewer with ScrollHtmlWidget)
-- =========================================================================

function Zhihu:showArticle(question_id, title, item_type, offset)
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{text = _("Device is offline."), timeout = 3})
        return
    end

    offset = tonumber(offset) or 0
    item_type = item_type or "answer"
    local show_images = self.settings:readSetting("show_images", false)

    -- v127: cut on a UTF-8 boundary instead of raw bytes
    local display_title = title or ""
    if #display_title > 30 then display_title = utf8Truncate(display_title, 29) .. "..." end
    local loading = InfoMessage:new{
        text = T(_("Loading: %1"), display_title),
        timeout = 0,
    }
    UIManager:show(loading)
    -- v140: force a repaint, otherwise the (blocking) request below freezes
    -- the screen before the loading hint is ever drawn.
    if UIManager.forceRePaint then
        pcall(function() UIManager:forceRePaint() end)
    end

    -- v140: fetch/render one page of answers (5) instead of the whole thread.
    -- v151: the avatar setting decides whether the page HTML carries an
    -- <img class="avatar"> at all (and which on-disk page cache is used).
    self.client.show_avatar = self:getShowAvatar()
    local html_content, page_info = self.client:getAnswersPage(
        question_id, title, item_type, offset, DEFAULT_PAGE_SIZE)

    if not html_content then
        local last_err = type(page_info) == "string" and page_info or (self.client:getLastError() or "")
        if offset > 0 then
            UIManager:close(loading)
            UIManager:show(InfoMessage:new{
                text = T(_("Load failed: %1"), last_err ~= "" and last_err or _("No more answers")),
                timeout = 6,
            })
            return
        end
        -- Fallback for the first page only: plain text, wrapped in basic HTML
        local text = self.client:getAnswers(question_id, title, item_type, false)
        UIManager:close(loading)
        if not text then
            UIManager:show(InfoMessage:new{
                text = T(_("Load failed: %1"), last_err),
                timeout = 8,
            })
            return
        end
        html_content = "<div class='title'>" .. (title or "") .. "</div>"
        local escaped = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        escaped = escaped:gsub("\n\n", "</p><p>")
        escaped = escaped:gsub("\n", "<br/>")
        html_content = html_content .. "<p>" .. escaped .. "</p>"
        page_info = { offset = 0, limit = DEFAULT_PAGE_SIZE, count = 1, has_more = false }
    else
        UIManager:close(loading)
    end

    page_info = page_info or {}
    local page_limit = tonumber(page_info.limit) or DEFAULT_PAGE_SIZE
    local has_more = page_info.has_more and true or false

    self.current_article = {
        question_id = question_id,
        title = title,
        item_type = item_type,
        image_list = {},
        page_offset = offset,
    }

    -- v140: remember the current batch so "next"/"previous" know what to load.
    self.read_ctx = {
        question_id = question_id,
        title = title,
        item_type = item_type,
        offset = offset,
        limit = page_limit,
        has_more = has_more,
    }

    local font_size = self.settings:readSetting("font_size", DEFAULT_FONT_SIZE)
    local font_name = self:getFontName()

    -- v140: "下一个" lives at the end of the page, right after the last answer.
    html_content = html_content .. self:_buildPageNav(offset, page_info)

    -- v151: author avatars. They live next to the batch's pictures (one folder
    -- per batch), are fetched before the viewer is built so the very first
    -- page already shows them, and are kept out of the picture pipeline below
    -- (they are neither numbered nor replaced by a "[图片N]" placeholder).
    local show_avatar = self:getShowAvatar()
    local avatar_ready = false
    local article_dir = nil
    if show_images or show_avatar then
        -- v140: each batch keeps its own image folder, so image numbering of
        -- one batch never overwrites the files of another.
        article_dir = DataStorage:getDataDir() .. "/zhihu_article_images/" .. question_id .. "/"
        if offset > 0 then
            article_dir = article_dir .. "p" .. offset .. "/"
        end
        os.execute("mkdir -p " .. shellQuote(article_dir))
    end
    if show_avatar and article_dir then
        local inlined, used = self:_inlineAvatars(html_content, article_dir)
        html_content = inlined
        avatar_ready = used and true or false
    else
        -- off: drop the markup itself, the answerer's name stays
        html_content = html_content:gsub('<img%s[^>]-class="avatar"[^>]*>', "")
    end

    -- Handle images: download to local dir (if enabled) or strip from HTML
    -- v124: Per-article cache with single-pass replacement.
    -- Each <img> is either replaced with local path (cached) or placeholder (pending).
    local image_dir = avatar_ready and article_dir or nil
    local pending_urls = nil
    -- v127 fix: hoisted to function scope so it is actually passed to ArticleViewer.
    local cached_map = {}
    local full_html = html_content
    if show_images then
        -- Extract image URLs from HTML
        local img_urls = {}
        local seen = {}
        html_content:gsub('<img[^>]-src="([^"]*)"', function(url)
            -- v151: avatars are already local files, not part of "View Images"
            if url and url ~= "" and url:match("^https?://") and not seen[url] then
                seen[url] = true
                table.insert(img_urls, url)
            end
        end)

        self.current_article.image_list = img_urls

        if #img_urls > 0 then
            pending_urls = {}
            local cached_count = 0
            local img_index = 0

            -- Single-pass: replace each <img> with either local file or placeholder
            html_content = html_content:gsub('<img([^>]*)>', function(attrs)
                -- v151: an avatar is a local file already; leave it alone and
                -- keep it out of the picture numbering (indexes must match the
                -- ones article_viewer counts on the same HTML).
                if attrs:find('class="avatar"', 1, true) then return nil end
                img_index = img_index + 1
                local url = attrs:match('src="([^"]*)"') or attrs:match("src='([^']*)")
                if not url or url == "" then
                    return '<div class="img-placeholder"><span class="img-num">[图片' .. img_index .. ']</span></div>'
                end

                local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
                local cached_name = nil
                local candidates = {
                    string.format("img_%03d.png", img_index),
                    string.format("img_%03d.%s", img_index, ext),
                }
                for _, name in ipairs(candidates) do
                    local f = io.open(article_dir .. name, "rb")
                    if f then
                        local size = f:seek("end") or 0
                        f:close()
                        if size > 0 and size <= CACHE_RENDER_LIMIT then
                            cached_name = name
                            break
                        elseif size > 0 then
                            os.remove(article_dir .. name)
                        end
                    end
                end

                if cached_name then
                    cached_count = cached_count + 1
                    cached_map[url] = cached_name
                    -- v147: hand the cached path over *with* the size
                    -- attributes. Dropping them made a cached picture render
                    -- at its intrinsic pixel size, i.e. tiny, while the same
                    -- picture looked right on the first visit.
                    local wpx = attrs:match('width%s*=%s*"(%d+)"')
                    local icls = attrs:match('class%s*=%s*"([^"]*)"')
                    local out = '<img src="' .. cached_name .. '"'
                    if wpx then out = out .. ' width="' .. wpx .. '"' end
                    if icls then out = out .. ' class="' .. icls .. '"' end
                    return out .. '/>'
                end

                -- Not cached: queue it for one background download
                table.insert(pending_urls, {url = url, index = img_index})
                return '<div class="img-placeholder"><span class="img-num">[图片' .. img_index .. ']</span></div>'
            end)

            if cached_count > 0 then
                image_dir = article_dir
            end
        end
    else
        local img_index = 0
        local img_urls = {}
        html_content = html_content:gsub('<img([^>]*)>', function(attrs)
            -- v151: avatars survive "Show Images" being off
            if attrs:find('class="avatar"', 1, true) then return nil end
            img_index = img_index + 1
            local url = attrs:match('src="([^"]*)"') or attrs:match("src='([^']*)")
            if url and url ~= "" then
                table.insert(img_urls, url)
            end
            return '<div class="img-placeholder"><span class="img-num">[图片' .. img_index .. ']</span></div>'
        end)
        self.current_article.image_list = img_urls
    end

    -- Try ArticleViewer first, fallback to TextViewer if it crashes
    local ok_viewer = pcall(function()
        local viewer = ArticleViewer:new{
            html_content = html_content,
            css = buildArticleCss(font_name, self:getParaIndent()),
            image_dir = image_dir,
            image_page_break = self:getImagePageBreak(),
            font_size = font_size,
            full_html = full_html,
            pending_urls = pending_urls,
            image_map = cached_map,
            article_dir = article_dir,
            plugin = self,
            -- v140: batch navigation, driven by the ScrollHtmlWidget link
            -- callback and by the bottom status bar buttons.
            has_next_page = has_more,
            has_prev_page = (offset > 0),
            on_next_page = function() self:_gotoAnswersPage(1) end,
            on_prev_page = function() self:_gotoAnswersPage(-1) end,
        }
        self.current_viewer = viewer
        UIManager:show(viewer)
    end)

    if not ok_viewer then
        self.current_viewer = nil
        -- Fallback to plain TextViewer if ArticleViewer crashes
        UIManager:show(InfoMessage:new{
            text = _("Article viewer unavailable, using text mode."),
            timeout = 2,
        })
        local plain_text = html_content:gsub("<[^>]*>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        UIManager:show(TextViewer:new{
            title = title or "",
            text = plain_text,
            text_face = Font:getFace("cfont", font_size),
            justified = true,
        })
    end
end

-- =========================================================================
-- v140: answer paging helpers
-- =========================================================================

-- HTML block placed after the last answer of the current batch.
function Zhihu:_buildPageNav(offset, info)
    info = info or {}
    local limit = tonumber(info.limit) or DEFAULT_PAGE_SIZE
    local count = tonumber(info.count) or limit
    local first_no = offset + 1
    local last_no = offset + count
    local parts = {}
    table.insert(parts, '<div class="page-nav">')
    if count > 0 then
        table.insert(parts, string.format('<p class="nav-hint">%s</p>',
            T(_("第 %1 - %2 条回答"), first_no, last_no)))
    end
    if info.has_more then
        table.insert(parts, string.format('<div class="nav-btn"><a href="zhihu://next">%s</a></div>',
            T(_("下一个（再看 %1 条）"), limit)))
    elseif offset > 0 then
        table.insert(parts, string.format('<p class="nav-hint">%s</p>', _("已经是最后一页了")))
    end
    if offset > 0 then
        table.insert(parts, string.format('<div class="nav-btn-small"><a href="zhihu://prev">%s</a></div>',
            _("‹ 上一批")))
    end
    table.insert(parts, '</div>')
    return table.concat(parts, "\n")
end

-- dir = 1 -> next batch, -1 -> previous batch
function Zhihu:_gotoAnswersPage(dir)
    local ctx = self.read_ctx
    if not ctx then return end
    local limit = tonumber(ctx.limit) or DEFAULT_PAGE_SIZE
    local new_offset = (tonumber(ctx.offset) or 0) + dir * limit
    if new_offset < 0 then new_offset = 0 end
    if new_offset == (tonumber(ctx.offset) or 0) then return end
    if dir > 0 and not ctx.has_more then
        UIManager:show(InfoMessage:new{text = _("No more answers"), timeout = 2})
        return
    end
    -- v140: close the current viewer first; otherwise stale widgets pile up
    -- and the device gets slower with every batch.
    if self.current_viewer then
        local viewer = self.current_viewer
        self.current_viewer = nil
        pcall(function() UIManager:close(viewer) end)
    end
    self:showArticle(ctx.question_id, ctx.title, ctx.item_type, new_offset)
end

-- =========================================================================
-- v140: font family setting
-- =========================================================================

function Zhihu:getFontName()
    local name = self.settings:readSetting("font_family", "")
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    return name
end

function Zhihu:setFontName(name)
    self.settings:saveSetting("font_family", name or "")
    self.updated = true
end

-- v148: should a content picture start on a page of its own?
function Zhihu:getImagePageBreak()
    return self.settings:readSetting("image_page_break", DEFAULT_IMAGE_PAGE_BREAK) == true
end

-- v146: first-line indent of a paragraph, in characters (0 or 2).
function Zhihu:getParaIndent()
    local v = self.settings:readSetting("para_indent", DEFAULT_PARA_INDENT)
    if v == 0 or v == "0" then return 0 end
    return DEFAULT_PARA_INDENT
end

-- v151: should the answerer's avatar be shown in front of the answer?
function Zhihu:getShowAvatar()
    return self.settings:readSetting("show_avatar", DEFAULT_SHOW_AVATAR) == true
end

-- v152: avatar side length = body font size x this factor (3 / 4 / 5)
function Zhihu:getAvatarScale()
    local v = tonumber(self.settings:readSetting("avatar_scale", DEFAULT_AVATAR_SCALE)) or DEFAULT_AVATAR_SCALE
    if v < 2 then v = 2 elseif v > 6 then v = 6 end
    return math.floor(v)
end

-- v151: deterministic, filesystem-safe file name for an avatar URL. The last
-- path segment of a Zhihu avatar is a content hash (v2-<hash>_m.jpg), so the
-- same author always maps to the same file and is downloaded exactly once.
function Zhihu:_avatarFileName(url)
    local tail = url:match("([^/%?]+)$") or "avatar.jpg"
    tail = tail:gsub("%?.*$", "")
    tail = tail:gsub("[^%w%._%-]", "_")
    if tail == "" or tail == "." or tail == ".." then tail = "avatar.jpg" end
    if #tail > 60 then tail = tail:sub(-60) end
    return "av_" .. tail
end

-- v151: turn every <img class="avatar" src="https://..."> into a local file
-- reference. Avatars are small and there are at most a handful per page, so
-- they are fetched right here (blocking, once) instead of going through the
-- background picture pipeline: that keeps them independent from "Show Images"
-- and they are on the very first page the reader sees. A failed download just
-- drops the picture and leaves the name.
function Zhihu:_inlineAvatars(html, dir)
    if not html or html == "" or not dir then return html, false end
    local used = false
    local resolved = {}
    -- v152: v151 sized the avatar at 1.4x the body font (~30px) and it was too
    -- small to make out on an e-ink screen. 4x the font size (or a bit less on
    -- a narrow screen) is a face you can actually recognise, while still
    -- fitting next to the author line.
    local font_size = tonumber(self.settings:readSetting("font_size", DEFAULT_FONT_SIZE)) or DEFAULT_FONT_SIZE
    local avatar_px = math.floor(font_size * self:getAvatarScale())
    local ok_w, screen_w = pcall(function() return Screen:getWidth() end)
    if ok_w and tonumber(screen_w) then
        local cap = math.floor(screen_w * 0.16)
        if avatar_px > cap then avatar_px = cap end
    end
    if avatar_px < 64 then avatar_px = 64 end
    html = html:gsub('<img([^>]-class="avatar"[^>]*)>', function(attrs)
        local url = attrs:match('src="([^"]*)"') or attrs:match("src='([^']*)'")
        if not url or url == "" then return "" end
        if not url:match("^https?://") then return nil end

        if resolved[url] == nil then
            local name = self:_avatarFileName(url)
            local path = dir .. name
            local f = io.open(path, "rb")
            local size = 0
            if f then size = f:seek("end") or 0 f:close() end
            if size > 0 then
                resolved[url] = name
            else
                -- v152: the feed hands out a small (_m/_s/_l) avatar, which is
                -- blurry once blown up to avatar_px. Ask for the _xl variant
                -- first and fall back to the original on any failure.
                local hi_url = url
                local u = url
                if u:match("_[mslb]%.jpg$") then
                    hi_url = u:gsub("_[mslb]%.jpg$", "_xl.jpg")
                end
                local name_hi = name
                if hi_url ~= url then
                    name_hi = (name:gsub("%.jpg$", "_xl.jpg"))
                    if name_hi == name then name_hi = name .. "_xl" end
                end
                local path_hi = dir .. name_hi
                local picked = false
                if hi_url ~= url then
                    local fh = io.open(path_hi, "rb")
                    local sh = 0
                    if fh then sh = fh:seek("end") or 0 fh:close() end
                    if sh > 0 then
                        picked = true
                        name, path = name_hi, path_hi
                    else
                        local okh = false
                        pcall(function()
                            okh = self.client:downloadFile(hi_url, path_hi, "https://www.zhihu.com/") and true or false
                        end)
                        local f2h = io.open(path_hi, "rb")
                        local s2h = 0
                        if f2h then s2h = f2h:seek("end") or 0 f2h:close() end
                        if okh and s2h > 0 then
                            picked = true
                            name, path = name_hi, path_hi
                        else
                            pcall(os.remove, path_hi)
                        end
                    end
                end
                if picked then
                    resolved[url] = name
                else
                    local ok = false
                    pcall(function()
                        ok = self.client:downloadFile(url, path, "https://www.zhihu.com/") and true or false
                    end)
                    local f2 = io.open(path, "rb")
                    local size2 = 0
                    if f2 then size2 = f2:seek("end") or 0 f2:close() end
                    if ok and size2 > 0 then
                        resolved[url] = name
                    else
                        pcall(os.remove, path)
                        resolved[url] = false
                    end
                end
            end
        end

        if resolved[url] then
            used = true
            return '<img class="avatar" src="' .. resolved[url]
                .. '" width="' .. avatar_px .. '" height="' .. avatar_px .. '"/>'
        end
        return ""
    end)
    return html, used
end

function Zhihu:buildFontMenu()
    local items = {}
    table.insert(items, {
        text = _("默认（内置中文字体栈）/ Default"),
        checked_func = function() return self:getFontName() == nil end,
        callback = function()
            self:setFontName(nil)
            UIManager:show(InfoMessage:new{text = _("字体：默认（重新打开文章生效）"), timeout = 2})
        end,
    })
    table.insert(items, {text = "----------------"})

    for _idx, name in ipairs(FONT_PRESETS) do
        table.insert(items, {
            text = name,
            checked_func = function() return self:getFontName() == name end,
            callback = function()
                self:setFontName(name)
                UIManager:show(InfoMessage:new{text = T(_("字体：%1（重新打开文章生效）"), name), timeout = 2})
            end,
        })
    end

    table.insert(items, {text = "----------------"})
    table.insert(items, {
        text = _("自定义字体名... / Custom Font Name"),
        checked_func = function()
            local n = self:getFontName()
            if not n then return false end
            for _i, preset in ipairs(FONT_PRESETS) do
                if preset == n then return false end
            end
            return true
        end,
        callback = function() self:showFontInput() end,
    })
    return items
end

function Zhihu:showFontInput()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("自定义字体名"),
        description = _("填写本机已安装的字体族名，\n例如 Noto Serif CJK SC"),
        input = self:getFontName() or "",
        buttons = {
            {
                {
                    text = _("取消 (Cancel)"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("应用 (Apply)"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText() or ""
                        value = value:gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        if value == "" then
                            self:setFontName(nil)
                            UIManager:show(InfoMessage:new{text = _("字体：默认（重新打开文章生效）"), timeout = 2})
                        else
                            self:setFontName(value)
                            UIManager:show(InfoMessage:new{text = T(_("字体：%1（重新打开文章生效）"), value), timeout = 2})
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        dialog:onShowKeyboard()
    end
end

-- =========================================================================
-- v140: page cache maintenance
-- =========================================================================

function Zhihu:clearPageCache()
    local removed = self.client:clearPageCache()
    UIManager:show(InfoMessage:new{
        text = T(_("Page cache cleared (%1 files)."), tonumber(removed) or 0),
        timeout = 2,
    })
end


-- =========================================================================
-- Image Viewer for Article Images
-- =========================================================================

function Zhihu:showImages()
    local plugin = self
    local images = self.current_article and self.current_article.image_list
    if not images or #images == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No images available."),
            timeout = 3,
        })
        return
    end

    local image_items = {}
    for i, url in ipairs(images) do
        table.insert(image_items, {
            text = T(_("Image %1"), i),
            image_url = url,
        })
    end

    local menu = Menu:new{
        title = _("Article Images"),
        item_table = image_items,
        covers_fullscreen = true,
        is_borderless = true,
    }

    function menu:onMenuSelect(entry)
        plugin:showImage(entry.image_url)
    end

    function menu:onClose()
        UIManager:close(menu)
        return true
    end

    UIManager:show(menu)
end

function Zhihu:showImage(url)
    if not url or url == "" then return end

    local loading = InfoMessage:new{text = _("Loading image..."), timeout = 0}
    UIManager:show(loading)

    -- Use URL-based unique filename so multiple images don't overwrite each other
    local safe_url = url:gsub("[^%w]", "_")
    -- v127 fix: keep the real extension instead of forcing .jpg
    -- (webp/png/gif images were being renamed to .jpg)
    local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
    local img_path = DataStorage:getDataDir() .. "/zhihu_img_" .. safe_url:sub(1, 80) .. "." .. ext
    local ok = pcall(function()
        self.client:_downloadImage(url, img_path)
    end)

    UIManager:close(loading)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Failed to load image."),
            timeout = 3,
        })
        return
    end

    local iv_ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    local ri_ok, RenderImage = pcall(require, "ui/renderimage")

    if iv_ok and ri_ok then
        local img_ok, image = pcall(function()
            return RenderImage:renderImageFile(img_path)
        end)

        if img_ok and image then
            local viewer_ok, viewer = pcall(function()
                return ImageViewer:new{
                    image = image,
                    title = _("Image"),
                    fullscreen = false,
                    with_title_bar = true,
                }
            end)

            if viewer_ok and viewer then
                UIManager:show(viewer)
                return
            end
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Image display not available."),
        timeout = 3,
    })
end

-- =========================================================================
-- Clear Image Cache
-- =========================================================================

function Zhihu:clearCache()
    local cache_dir = DataStorage:getDataDir() .. "/zhihu_article_images/"
    local ok = os.execute("rm -rf " .. shellQuote(cache_dir))
    if ok then
        UIManager:show(InfoMessage:new{
            text = _("Image cache cleared."),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Failed to clear cache."),
            timeout = 2,
        })
    end
end

-- =========================================================================
-- Export article as HTML with local images
-- =========================================================================

function Zhihu:exportHtml()
    if not self.current_article then
        UIManager:show(InfoMessage:new{text = _("No article to export."), timeout = 3})
        return
    end

    -- Step 1: Get HTML content
    local loading = InfoMessage:new{text = _("Fetching article..."), timeout = 0}
    UIManager:show(loading)

    local article = self.current_article
    local html_content = self.client:getAnswersHtml(
        article.question_id,
        article.title,
        article.item_type
    )

    UIManager:close(loading)

    if not html_content or html_content == "" then
        UIManager:show(InfoMessage:new{
            text = _("Failed to generate HTML content."),
            timeout = 3,
        })
        return
    end

    -- Step 2: Prepare directory with safe filename
    local title = article.title or "Zhihu Article"
    local timestamp = os.time()
    
    local safe_title = title:gsub("[\\/:*?\"<>|]", "_")
    safe_title = safe_title:gsub("^%s+", ""):gsub("%s+$", "")
    safe_title = safe_title:gsub("%s+", "_")
    if #safe_title > 50 then safe_title = safe_title:sub(1, 50) end
    if safe_title == "" then safe_title = "zhihu" end
    
    -- Fallback filename using question_id if title-based fails
    local fallback_name = "zhihu_" .. tostring(article.question_id or "article") .. "_" .. timestamp

    local export_dir = DataStorage:getDataDir() .. "/zhihu_exports"
    local article_dir = export_dir .. "/" .. safe_title .. "_" .. timestamp
    local images_dir = article_dir .. "/images"

    -- Try to create directory
    local mkdir_ok = os.execute("mkdir -p " .. shellQuote(images_dir))
    if not mkdir_ok then
        -- Fallback: try without spaces/special chars in path
        article_dir = export_dir .. "/" .. fallback_name
        images_dir = article_dir .. "/images"
        os.execute("mkdir -p " .. shellQuote(images_dir))
    end

    -- Step 3: Collect <img> source URLs from the exported HTML, then inline them as base64.
    -- NOTE: we map by URL (not by positional index) so images stay correct even when the
    -- freshly re-fetched HTML differs in order from the reading-time image list.
    local img_urls = {}
    local seen = {}
    html_content:gsub('<img[^>]-src="([^"]*)"', function(url)
        if url and url ~= "" and not seen[url] then
            seen[url] = true
            table.insert(img_urls, url)
        end
    end)
    local total_images = #img_urls
    local downloaded_count = 0
    local url_base64 = {} -- url -> "data:..." string

    -- Helper: read file as binary string
    local function readBinaryFile(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end

    -- Helper: base64 encode (pure Lua, no external lib needed)
    local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
    local function base64Encode(data)
        local out = {}
        local b64 = base64_chars
        for i = 1, #data, 3 do
            local a, b, c = string.byte(data, i, i + 2)
            local n = a * 65536 + (b or 0) * 256 + (c or 0)
            local s = b64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
            s = s .. b64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
            s = s .. (b and b64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
            s = s .. (c and b64:sub(n % 64 + 1, n % 64 + 1) or "=")
            table.insert(out, s)
        end
        return table.concat(out)
    end

    local function downloadAndEncode(url)
        local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
        local tmp_path = export_dir .. "/_tmp_img_" .. timestamp .. "_" .. math.random(100000, 999999)
        local ok = pcall(function()
            self.client:_downloadImage(url, tmp_path)
        end)
        if not ok then return nil end
        local data = readBinaryFile(tmp_path)
        pcall(function() os.remove(tmp_path) end)
        if not data or #data == 0 then return nil end
        -- v130: no size limit — all images are exported (was capped at 3MB)
        local mime = (ext == "png") and "image/png" or (ext == "gif") and "image/gif" or "image/jpeg"
        return "data:" .. mime .. ";base64," .. base64Encode(data)
    end

    for i, url in ipairs(img_urls) do
        UIManager:show(InfoMessage:new{
            text = T(_("Downloading images (%1/%2)..."), i, total_images),
            timeout = 0,
        })
        local data_url = downloadAndEncode(url)
        if data_url then
            url_base64[url] = data_url
            downloaded_count = downloaded_count + 1
        end
    end

    -- Step 4: Replace each <img src="url"> with its inline base64 data URL (matched by URL)
    html_content = html_content:gsub('(<img[^>]-)src="([^"]*)"', function(prefix, url)
        local data_url = url_base64[url]
        if data_url then
            return prefix .. 'src="' .. data_url .. '"'
        end
        return prefix .. 'src="' .. url .. '"'
    end)

    -- Step 5: Generate full HTML document with large e-ink friendly fonts
    local full_html = '<html>\n'
        .. '<head>\n'
        .. '<meta charset="UTF-8">\n'
        .. '<title>' .. title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") .. '</title>\n'
        .. '<style type="text/css">\n'
        .. '*{margin:0;padding:0;}\n'
        .. 'body{font-family:serif;line-height:2.2;font-size:36px;color:#000;}\n'
        .. '.title{font-size:38px;font-weight:bold;text-align:center;margin:0;padding:10px 0 15px 0;border-bottom:3px solid #000;}\n'
        .. 'p{text-indent:' .. (self:getParaIndent() == 0 and "0" or "2em") .. ';margin:0 0 15px 0;}\n'
        .. '.answer{margin:0 0 30px 0;padding:0 0 20px 0;border-bottom:2px dashed #888;}\n'
        .. '.author{font-weight:bold;font-size:28px;color:#000;margin:0 0 5px 0;text-indent:0;}\n'
        .. '.voteup{font-size:22px;color:#444;margin:0 0 15px 0;text-indent:0;}\n'
        .. 'img{max-width:100%;height:auto;display:block;margin:15px auto;border:2px solid #666;}\n'
        .. 'blockquote{border-left:5px solid #888;padding:10px 20px;margin:15px 0;color:#222;}\n'
        .. 'blockquote p{text-indent:0;}\n'
        .. 'li{margin:0 0 10px 0;font-size:36px;}\n'
        .. 'code{font-family:monospace;font-size:28px;}\n'
        .. 'pre{padding:15px;border:2px solid #888;overflow-x:auto;font-size:28px;}\n'
        .. 'pre p{text-indent:0;}\n'
        .. 'h2{font-size:36px;font-weight:bold;margin:20px 0 15px 0;}\n'
        .. 'h3{font-size:34px;font-weight:bold;margin:15px 0 10px 0;}\n'
        .. '</style>\n'
        .. '</head>\n'
        .. '<body><!--start-->'
        .. html_content
        .. '</body>\n'
        .. '</html>'

    -- Step 5: Save HTML file with retry
    local html_path = article_dir .. "/index.html"
    local f = io.open(html_path, "w")
    
    -- Retry with fallback path if first attempt fails
    if not f then
        article_dir = export_dir .. "/" .. fallback_name
        os.execute("mkdir -p " .. shellQuote(article_dir))
        html_path = article_dir .. "/index.html"
        f = io.open(html_path, "w")
    end
    
    if not f then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to write HTML file.\nPath: %1"), html_path),
            timeout = 5,
        })
        return
    end

    f:write(full_html)
    f:flush()
    f:close()

    -- Step 6: Show success and auto-open
    UIManager:show(InfoMessage:new{
        text = T(_("HTML exported to:\n%1\nImages: %2/%3"), html_path, downloaded_count, total_images),
        timeout = 2,
    })

    -- Auto-open in KOReader
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI then
        pcall(function()
            ReaderUI:showReader(html_path)
        end)
    end
end

-- =========================================================================
-- Export article as EPUB
-- =========================================================================

function Zhihu:exportEpub()
    if not self.current_article then
        UIManager:show(InfoMessage:new{text = _("No article to export."), timeout = 3})
        return
    end

    local article = self.current_article
    local loading = InfoMessage:new{text = _("Fetching article..."), timeout = 0}
    UIManager:show(loading)

    local html_content = self.client:getAnswersHtml(
        article.question_id,
        article.title,
        article.item_type
    )

    UIManager:close(loading)

    if not html_content or html_content == "" then
        UIManager:show(InfoMessage:new{
            text = _("Failed to fetch article content."),
            timeout = 5,
        })
        return
    end

    -- Step 2: Prepare safe filename
    local title = article.title or "Zhihu Article"
    local timestamp = os.time()
    
    local safe_title = title:gsub("[\\/:*?\"<>|%c]", "_")
    safe_title = safe_title:gsub("^%s+", ""):gsub("%s+$", "")
    safe_title = safe_title:gsub("%s+", "_")
    if #safe_title > 50 then safe_title = safe_title:sub(1, 50) end
    if safe_title == "" then safe_title = "zhihu" end
    
    local export_dir = DataStorage:getDataDir() .. "/zhihu_exports"
    local epub_name = safe_title .. "_" .. timestamp .. ".epub"
    local epub_path = export_dir .. "/" .. epub_name

    -- Ensure export directory exists
    os.execute("mkdir -p " .. shellQuote(export_dir))

    -- Step 3: Download all images to a temp directory
    local article_dir = export_dir .. "/epub_temp_" .. timestamp
    local images_dir = article_dir .. "/images"
    os.execute("mkdir -p " .. shellQuote(images_dir))

    -- Extract image URLs
    local img_urls = {}
    local seen = {}
    html_content:gsub('<img[^>]-src="([^"]*)"', function(url)
        if url and url ~= "" and not seen[url] then
            seen[url] = true
            table.insert(img_urls, url)
        end
    end)

    -- Download images (v129: with visible progress and a size cap so an
    -- image-heavy article cannot stall the export for minutes on end)
    local url_to_file = {}
    local progress_msg = nil
    for i, url in ipairs(img_urls) do
        if progress_msg then
            pcall(function() UIManager:close(progress_msg) end)
        end
        progress_msg = InfoMessage:new{
            text = T(_("Downloading images (%1/%2)..."), i, #img_urls),
            timeout = 0,
        }
        UIManager:show(progress_msg)

        local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
        local filename = string.format("img_%03d.%s", i, ext)
        local filepath = images_dir .. "/" .. filename

        local dl_ok, dl_result = pcall(function()
            return self.client:_downloadImage(url, filepath)
        end)
        if dl_ok and dl_result then
            -- Verify the file exists (v130: no size cap — export all images)
            local f = io.open(filepath, "rb")
            if f then
                f:close()
                url_to_file[url] = filepath
            end
        end
    end
    if progress_msg then
        pcall(function() UIManager:close(progress_msg) end)
    end

    -- Replace img src with absolute paths for EpubBuilder
    for url, filepath in pairs(url_to_file) do
        local esc_url = url:gsub("([%%%.%-%+%[%]%(%)%*%?%^%$])", "%%%1")
        -- v127 fix: function replacement so "%" in paths is not treated
        -- as a magic character by gsub
        html_content = html_content:gsub(
            'src="' .. esc_url .. '"',
            function() return 'src="' .. filepath .. '"' end
        )
    end

    -- Step 4: Build EPUB using epub_builder
    local ok_builder, EpubBuilder = pcall(require, "epub_builder")
    if not ok_builder then
        UIManager:show(InfoMessage:new{
            text = _("EPUB builder not available."),
            timeout = 3,
        })
        return
    end

    local book = {
        title = title,
        identifier = "zhihu-" .. (article.question_id or "article") .. "-" .. timestamp,
        date = os.date("!%Y-%m-%d"),
        chapters = {
            {
                title = title,
                meta = "",
                body = html_content,
            },
        },
    }

    local ok, result = pcall(function()
        return EpubBuilder.build(book, epub_path)
    end)

    -- Cleanup temp directory
    os.execute("rm -rf " .. shellQuote(article_dir))

    if ok and result then
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB exported to:\n%1"), epub_path),
            timeout = 3,
        })
        -- Auto-open in KOReader
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_reader and ReaderUI then
            pcall(function()
                ReaderUI:showReader(epub_path)
            end)
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB export failed: %1"), tostring(result)),
            timeout = 5,
        })
    end
end

return Zhihu