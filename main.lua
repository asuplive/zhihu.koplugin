--[[
    Zhihu Reader Plugin for KOReader v127
    - QR code login: auto-completing poll login
    - Recommended feed (12 items per batch) with Load More cursor
    - ArticleViewer with ScrollHtmlWidget for reading (native page turn)
    - Mixed text and image display (图文混排)
    - Export to HTML & EPUB with auto-open
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
local QR_POLL_INTERVAL = 3
local QR_MAX_POLLS = 40

-- CSS for ScrollHtmlWidget article rendering
local ARTICLE_CSS = [[
html, body {
    font-family: "Noto Serif CJK SC", "WenQuanYi Micro Hei", serif;
    line-height: 1.8;
    color: #000;
    margin: 0;
    padding: 0;
}
a {
    color: #000;
    text-decoration: none;
}
.img-placeholder {
    display: block;
    width: 33%;
    height: 180px;
    border: 2px solid #000;
    text-align: center;
    line-height: 180px;
    margin: 10px auto;
}
.img-num {
    font-size: 1.5em;
    font-weight: bold;
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
.author {
    font-style: italic;
    margin-bottom: 2px;
}
h2.author {
    font-size: 1.3em;
    font-weight: bold;
}
.answer {
    margin-bottom: 12px;
    padding-bottom: 8px;
    border-bottom: 1px dashed #888;
    margin-top: 0;
}
.author {
    font-weight: bold;
    font-style: italic;
    margin-bottom: 2px;
}
.voteup {
    color: #666;
    margin-bottom: 6px;
    font-style: italic;
}
p {
    text-indent: 0.5em;
    margin: 0 0 4px 0;
}
img {
    width: 100%;
    max-width: 100%;
    height: auto;
    display: block;
    margin: 0;
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
]]

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
        text = _("Zhihu Reader"),
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
            table.insert(sub_items, {text = _("User: ") .. user_name, enabled = false})
        end
        table.insert(sub_items, {
            text = _("Recommended Feed"),
            callback = function() self:showRecommendFeed() end,
        })
        table.insert(sub_items, {
            text = _("Logout"),
            callback = function() self:doLogout() end,
        })
    else
        table.insert(sub_items, {
            text = _("Login with QR Code"),
            callback = function() self:startQrLogin() end,
        })
    end

    table.insert(sub_items, {
        text = "Font Size",
        sub_item_table = {
            {text = _("Small (18)"),  checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 18 end,
             callback = function() self.settings:saveSetting("font_size", 18) self.updated = true end},
            {text = _("Medium (22)"), checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 22 end,
             callback = function() self.settings:saveSetting("font_size", 22) self.updated = true end},
            {text = _("Large (26)"),  checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 26 end,
             callback = function() self.settings:saveSetting("font_size", 26) self.updated = true end},
            {text = _("Extra Large (30)"), checked_func = function() return self.settings:readSetting("font_size", DEFAULT_FONT_SIZE) == 30 end,
             callback = function() self.settings:saveSetting("font_size", 30) self.updated = true end},
        },
    })

    table.insert(sub_items, {
        text = _("Show Images"),
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
        text = _("View Images"),
        enabled_func = function()
            return self.current_article ~= nil
                and self.current_article.image_list
                and #self.current_article.image_list > 0
        end,
        callback = function() self:showImages() end,
    })

    table.insert(sub_items, {
        text = _("Clear Image Cache"),
        callback = function() self:clearCache() end,
    })

    table.insert(sub_items, {
        text = _("Export HTML"),
        enabled_func = function()
            return self.current_article ~= nil
        end,
        callback = function() self:exportHtml() end,
    })

    table.insert(sub_items, {
        text = _("Export EPUB"),
        enabled_func = function()
            return self.current_article ~= nil
        end,
        callback = function() self:exportEpub() end,
    })

    table.insert(sub_items, {
        text = _("About"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Zhihu Reader v127\n\n- QR code login (auto-complete)\n- Recommended feed: 12 items per batch\n- ArticleViewer with optimized layout\n- Mixed text and images\n- Export to HTML & EPUB (auto-open)"),
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
        local ok, status = pcall(function() return plugin.client:checkScanStatus(token) end)
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
        else
            -- "waiting" or "scanned": keep polling.
            plugin._login_poll_timer = UIManager:scheduleIn(2.5, poll)
        end
    end
    self._login_poll_timer = UIManager:scheduleIn(1.5, poll)
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
    self:_loadFeedMenu(items, _("Recommended Feed"), true)
end

-- =========================================================================
-- Read Article (ArticleViewer with ScrollHtmlWidget)
-- =========================================================================

function Zhihu:showArticle(question_id, title, item_type)
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{text = _("Device is offline."), timeout = 3})
        return
    end

    local show_images = self.settings:readSetting("show_images", false)

    -- v127: cut on a UTF-8 boundary instead of raw bytes
    local display_title = title or ""
    if #display_title > 30 then display_title = utf8Truncate(display_title, 29) .. "..." end
    local loading = InfoMessage:new{
        text = T(_("Loading: %1"), display_title),
        timeout = 0,
    }
    UIManager:show(loading)

    -- Get HTML content from zhihu_client
    local html_content = self.client:getAnswersHtml(question_id, title, item_type)

    if not html_content then
        -- Fallback: try text version and wrap in basic HTML
        local text = self.client:getAnswers(question_id, title, item_type, false)
        UIManager:close(loading)
        if not text then
            local last_err = self.client:getLastError() or ""
            UIManager:show(InfoMessage:new{
                text = T(_("Load failed: %1"), last_err),
                timeout = 8,
            })
            return
        end
        -- Convert plain text to simple HTML
        html_content = "<div class='title'>" .. (title or "") .. "</div>"
        local escaped = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        escaped = escaped:gsub("\n\n", "</p><p>")
        escaped = escaped:gsub("\n", "<br/>")
        html_content = html_content .. "<p>" .. escaped .. "</p>"
    else
        UIManager:close(loading)
    end

    self.current_article = {
        question_id = question_id,
        title = title,
        item_type = item_type,
        image_list = {},
    }

    local font_size = self.settings:readSetting("font_size", DEFAULT_FONT_SIZE)

    -- Handle images: download to local dir (if enabled) or strip from HTML
    -- v124: Per-article cache with single-pass replacement.
    -- Each <img> is either replaced with local path (cached) or placeholder (pending).
    local image_dir = nil
    local pending_urls = nil
    -- v127 fix: hoisted to function scope so it is actually passed to ArticleViewer.
    -- (Previously declared inside the `if` block, so `image_map = cached_map` below
    -- read an undefined global and the v126 "keep cached images on refresh" fix
    -- never took effect.)
    local cached_map = {}
    local full_html = html_content
    local article_dir = nil
    if show_images then
        -- Create article-specific cache directory
        article_dir = DataStorage:getDataDir() .. "/zhihu_article_images/" .. question_id .. "/"
        os.execute("mkdir -p " .. shellQuote(article_dir))

        -- Extract image URLs from HTML
        local img_urls = {}
        local seen = {}
        html_content:gsub('<img[^>]-src="([^"]*)"', function(url)
            if url and url ~= "" and not seen[url] then
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
                img_index = img_index + 1
                local url = attrs:match('src="([^"]*)"') or attrs:match("src='([^']*)")
                if not url or url == "" then
                    return '<div class="img-placeholder"><span class="img-num">[图片' .. img_index .. ']</span></div>'
                end

                local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
                local filename = string.format("img_%03d.%s", img_index, ext)
                local filepath = article_dir .. filename

                -- Check cache
                local f = io.open(filepath, "rb")
                if f then
                    f:close()
                    cached_count = cached_count + 1
                    cached_map[url] = filename
                    return '<img src="' .. filename .. '" alt=""/>'
                else
                    table.insert(pending_urls, {url = url, index = img_index})
                    return '<div class="img-placeholder"><span class="img-num">[图片' .. img_index .. ']</span></div>'
                end
            end)

            if cached_count > 0 then
                image_dir = article_dir
            end
        end
    else
        local img_index = 0
        local img_urls = {}
        html_content = html_content:gsub('<img([^>]*)>', function(attrs)
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
        UIManager:show(ArticleViewer:new{
            html_content = html_content,
            css = ARTICLE_CSS,
            image_dir = image_dir,
            font_size = font_size,
            -- v122: Pass cache info for background download
            full_html = full_html,
            pending_urls = pending_urls,
            image_map = cached_map,
            article_dir = article_dir,
            plugin = self,
        })
    end)

    if not ok_viewer then
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
        .. 'p{text-indent:2em;margin:0 0 15px 0;}\n'
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

    -- Download images
    local url_to_file = {}
    for i, url in ipairs(img_urls) do
        local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
        local filename = string.format("img_%03d.%s", i, ext)
        local filepath = images_dir .. "/" .. filename

        local dl_ok, dl_result = pcall(function()
            return self.client:_downloadImage(url, filepath)
        end)
        if dl_ok and dl_result then
            -- Verify file exists
            local f = io.open(filepath, "rb")
            if f then
                f:close()
                url_to_file[url] = filepath
            end
        end
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