--[[
    Zhihu Reader Plugin for KOReader v81
    - QR code login: ImageViewer with QR image
    - Recommended feed with refresh button
    - ArticleViewer with ScrollHtmlWidget for reading (native page turn)
    - Close button in article viewer
    - Mixed text and image display (图文混排)
    - Export to HTML with images
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

local ZhihuClient  = require("zhihu_client")
local ArticleViewer = require("article_viewer")

local DEFAULT_FONT_SIZE = 22

-- CSS for ScrollHtmlWidget article rendering
local ARTICLE_CSS = [[
body {
    font-family: "Noto Serif CJK SC", "WenQuanYi Micro Hei", serif;
    line-height: 1.8;
    color: #000;
    margin: 0;
    padding: 0px;
}
a {
    color: #000;
    font-weight: bold;
    text-decoration: none;
}
.close-link {
    float: right;
    font-weight: bold;
}

.title {
    font-weight: bold;
    text-align: left;
    border-bottom: 2px solid #000;
    padding-bottom: 10px;
    margin-bottom: 15px;
}
.answer {
    margin-bottom: 25px;
    padding-bottom: 15px;
    border-bottom: 1px dashed #888;
}
.author {
    font-weight: bold;
    margin-bottom: 3px;
}
.voteup {
    color: #666;
    margin-bottom: 10px;
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
    margin: 10px 0;
    border: 1px solid #666;
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
    self.client = ZhihuClient:new()
    self.client:init(DataStorage:getSettingsDir())
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
    local pending = self.pending_token ~= nil

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
    elseif pending then
        table.insert(sub_items, {
            text = _("Complete Login"),
            callback = function() self:completeQrLogin() end,
        })
        table.insert(sub_items, {
            text = _("Cancel Login"),
            callback = function() self:cancelQrLogin() end,
        })
    else
        table.insert(sub_items, {
            text = _("Login with QR Code"),
            callback = function() self:startQrLogin() end,
        })
    end

    table.insert(sub_items, {text = "", separator = true})

    table.insert(sub_items, {
        text = _("Font Size"),
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
        text = _("Export HTML"),
        enabled_func = function()
            return self.current_article ~= nil
        end,
        callback = function() self:exportHtml() end,
    })

    table.insert(sub_items, {
        text = _("About"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Zhihu Reader v81\n\n- QR code login\n- Recommended feed with refresh\n- ArticleViewer with boundary close\n- Mixed text and images (图文混排)\n- Export to HTML"),
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

    -- v35: Generate token but do NOT start polling
    local token = self.client:generateQrToken()
    if not token then
        UIManager:show(InfoMessage:new{text = _("Failed to generate QR code."), timeout = 3})
        return
    end
    self.pending_token = token

    -- v35: Try ImageViewer first, then fallback to TextViewer URL
    local qr_url = self.client:getQrImageUrl(token)
    if qr_url then
        local iv_ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
        local ri_ok, RenderImage = pcall(require, "ui/renderimage")
        local dm_ok, DownloadManager = pcall(require, "ui/downloadmgr")

        if iv_ok and ri_ok then
            local qr_path = DataStorage:getDataDir() .. "/zhihu_qr.png"
            local downloaded = false

            if dm_ok and DownloadManager then
                downloaded = pcall(function()
                    DownloadManager:new{
                        url = qr_url,
                        download_path = qr_path,
                        onSuccess = function()
                            local img_ok, image = pcall(function()
                                return RenderImage:renderImageFile(qr_path)
                            end)
                            if img_ok and image then
                                local viewer_ok, viewer = pcall(function()
                                    return ImageViewer:new{
                                        image = image,
                                        title = _("Scan with Zhihu App"),
                                        fullscreen = true,
                                        with_title_bar = true,
                                    }
                                end)
                                if viewer_ok and viewer then
                                    UIManager:show(viewer)
                                    return true
                                end
                            end
                        end,
                    }:startDownload()
                end)
            end

            if not downloaded then
                -- Direct download fallback
                downloaded = pcall(function()
                    self.client:_downloadImage(qr_url, qr_path)
                end)
                if downloaded then
                    local img_ok, image = pcall(function()
                        return RenderImage:renderImageFile(qr_path)
                    end)
                    if img_ok and image then
                        local viewer_ok, viewer = pcall(function()
                            return ImageViewer:new{
                                image = image,
                                title = _("Scan with Zhihu App"),
                                fullscreen = true,
                                with_title_bar = true,
                            }
                        end)
                        if viewer_ok and viewer then
                            UIManager:show(viewer)
                            return
                        end
                    end
                end
            end
        end
    end

    -- Fallback: show URL text in TextViewer
    local scan_url = self.client:getScanUrl(token)
    UIManager:show(TextViewer:new{
        title = _("Login with Zhihu App"),
        text = _("1. Open Zhihu app on your phone\n")
            .. _("2. Tap the scan icon (top-right)\n")
            .. _("3. Scan or enter this URL:\n\n")
            .. scan_url
            .. "\n\n"
            .. _("4. Confirm login on your phone\n")
            .. _("5. Close this and tap 'Complete Login' in menu"),
        text_face = Font:getFace("cfont", 20),
        justified = false,
    })
end

function Zhihu:completeQrLogin()
    if not self.pending_token then
        UIManager:show(InfoMessage:new{text = _("No pending login."), timeout = 3})
        return
    end

    -- v33: Remove loading widget, avoid widget lifecycle crash on Android
    local ok, status = pcall(function()
        return self.client:checkScanStatus(self.pending_token)
    end)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Login check failed: %1"), tostring(status)),
            timeout = 5,
        })
        return
    end

    if status == "confirmed" then
        self.client:saveCookies()
        self.pending_token = nil
        self.cached_user_name = self.client:getUserName()
        UIManager:show(InfoMessage:new{text = _("Login successful!"), timeout = 5})
    elseif status == "expired" then
        self.pending_token = nil
        UIManager:show(InfoMessage:new{text = _("QR expired. Try again."), timeout = 3})
    elseif status == "scanned" then
        UIManager:show(InfoMessage:new{
            text = _("Scanned but not confirmed.\nPlease confirm on phone."),
            timeout = 4,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Not confirmed yet.\nPlease confirm on phone and try again."),
            timeout = 4,
        })
    end
end

function Zhihu:cancelQrLogin()
    self.pending_token = nil
    UIManager:show(InfoMessage:new{text = _("Login cancelled."), timeout = 2})
end

function Zhihu:doLogout()
    self.client:logout()
    self.pending_token = nil
    self.cached_user_name = nil
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
    self:_loadRecommendFeed(0)
end

function Zhihu:_loadRecommendFeed(offset)
    offset = offset or 0

    if not self.client:isLoggedIn() then
        UIManager:show(InfoMessage:new{text = _("Please login first."), timeout = 3})
        return
    end

    local loading = InfoMessage:new{text = _("Loading..."), timeout = 0}
    UIManager:show(loading)

    local items, err = self.client:getRecommendFeed(offset)
    UIManager:close(loading)

    if not items then
        local diag = tostring(err or "unknown")
        local last_err = self.client:getLastError() or ""
        if last_err ~= "" then diag = diag .. "\n(" .. last_err .. ")" end
        UIManager:show(InfoMessage:new{text = T(_("Load failed: %1"), diag), timeout = 8})
        return
    end

    local menu_items = {}
    for _, item in ipairs(items) do
        local text = item.title or "No Title"
        if item.author and item.author ~= "" then
            text = text .. "\n  -- " .. item.author
        end
        -- Show image link on second line if available
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

    -- Add refresh button at the bottom
    table.insert(menu_items, {
        text = _(">>> Refresh >>>"),
        callback = function() end,  -- Dummy callback, handled in onMenuSelect
    })

    local menu = Menu:new{
        title = _("Recommended Feed"),
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
    }

    local plugin = self
    function menu:onMenuSelect(entry)
        if entry.text == _(">>> Refresh >>>") then
            UIManager:close(menu)
            plugin:_loadRecommendFeed(offset + 20)
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

-- =========================================================================
-- Read Article (ArticleViewer with ScrollHtmlWidget)
-- =========================================================================

function Zhihu:showArticle(question_id, title, item_type)
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{text = _("Device is offline."), timeout = 3})
        return
    end

    local show_images = self.settings:readSetting("show_images", false)

    local loading = InfoMessage:new{
        text = T(_("Loading: %1"), title and #title > 30 and title:sub(1, 30) .. "..." or (title or "")),
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

    -- Handle images: download to local dir (if enabled) or strip from HTML
    local image_dir = nil
    if show_images then
        local temp_dir = DataStorage:getDataDir() .. "/zhihu_article_images/"
        os.execute("mkdir -p '" .. temp_dir .. "'")

        -- Extract image URLs from HTML
        local img_urls = {}
        local seen = {}
        html_content:gsub('<img[^>]-src="([^"]*)"', function(url)
            if url and url ~= "" and not seen[url] then
                seen[url] = true
                table.insert(img_urls, url)
            end
        end)

        -- Store URLs for backward-compatible View Images menu
        self.current_article.image_list = img_urls

        if #img_urls > 0 then
            local url_to_file = {}
            for i, url in ipairs(img_urls) do
                local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
                if ext == "webp" then ext = "jpg" end -- fallback for unsupported formats
                local filename = string.format("img_%03d.%s", i, ext)
                local filepath = temp_dir .. filename

                local ok = pcall(function()
                    self.client:_downloadImage(url, filepath)
                end)

                if ok then
                    url_to_file[url] = filename
                end
            end

            -- Replace remote URLs with local filenames in HTML
            for url, filename in pairs(url_to_file) do
                -- Escape pattern-special characters in URL
                local esc_url = url:gsub("([%%%.%-%+%[%]%(%)%*%?%^%$])", "%%%1")
                html_content = html_content:gsub(
                    'src="' .. esc_url .. '"',
                    'src="' .. filename .. '"'
                )
            end

            if next(url_to_file) then
                image_dir = temp_dir
            end
        end
    else
        -- show_images is off: replace img tags with placeholder text
        html_content = html_content:gsub('<img[^>]*/>', '[图片]')
    end

    local font_size = self.settings:readSetting("font_size", DEFAULT_FONT_SIZE)

    -- Try ArticleViewer first, fallback to TextViewer if it crashes
    local ok_viewer = pcall(function()
        UIManager:show(ArticleViewer:new{
            html_content = html_content,
            css = ARTICLE_CSS,
            image_dir = image_dir,
            font_size = font_size,
        })
    end)

    if not ok_viewer then
        -- Fallback to plain TextViewer if ArticleViewer crashes
        UIManager:show(InfoMessage:new{
            text = _("Article viewer unavailable, using text mode."),
            timeout = 2,
        })
        local plain_text = html_content:gsub("<[^>]-[>]-", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
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
        width = 800,
        height = 900,
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

    -- Download image to temp file
    local img_path = DataStorage:getDataDir() .. "/zhihu_image.jpg"
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
    
    -- Generate safe filename: remove ALL non-alphanumeric chars except basic ASCII
    local safe_title = title:gsub("[^%w%s%-]", "_")
    safe_title = safe_title:gsub("^%s+", ""):gsub("%s+$", "")
    safe_title = safe_title:gsub("%s+", "_")
    if #safe_title > 30 then safe_title = safe_title:sub(1, 30) end
    if safe_title == "" then safe_title = "zhihu" end
    
    -- Fallback filename using question_id if title-based fails
    local fallback_name = "zhihu_" .. tostring(article.question_id or "article") .. "_" .. timestamp

    local export_dir = DataStorage:getDataDir() .. "/zhihu_exports"
    local article_dir = export_dir .. "/" .. safe_title .. "_" .. timestamp
    local images_dir = article_dir .. "/images"

    -- Try to create directory
    local mkdir_ok = os.execute("mkdir -p " .. images_dir)
    if not mkdir_ok then
        -- Fallback: try without spaces/special chars in path
        article_dir = export_dir .. "/" .. fallback_name
        images_dir = article_dir .. "/images"
        os.execute("mkdir -p " .. images_dir)
    end

    -- Step 3: Download images with progress and inline as base64
    local images = article.image_list or {}
    local total_images = #images
    local downloaded_count = 0
    local img_base64_map = {} -- index -> {name, base64, mime} mapping

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

    if total_images > 0 then
        for i, url in ipairs(images) do
            -- Show progress
            UIManager:show(InfoMessage:new{
                text = T(_("Downloading images (%1/%2)..."), i, total_images),
                timeout = 0,
            })

            local ext = url:match("%.(%w+)$") or "jpg"
            local img_name = string.format("img_%03d.%s", i, ext)
            local img_path = images_dir .. "/" .. img_name
            local tmp_path = export_dir .. "/_tmp_img_" .. timestamp .. "_" .. i

            local ok = pcall(function()
                self.client:_downloadImage(url, tmp_path)
            end)

            if ok then
                -- Move temp file to images dir (keep for file manager viewing)
                os.execute("mv " .. tmp_path .. " " .. img_path)
                downloaded_count = downloaded_count + 1

                -- Read image and encode to base64 for inline embedding
                local img_data = readBinaryFile(img_path)
                if img_data and #img_data > 0 then
                    local mime_type = (ext == "png") and "image/png" or "image/jpeg"
                    local b64 = base64Encode(img_data)
                    img_base64_map[i] = {
                        mime = mime_type,
                        data = b64,
                    }
                end
            end
        end
    end

    -- Step 4: Replace each <img> src with inline base64 data URL
    local img_idx = 0
    local new_html_parts = {}
    local last_pos = 1
    local html_len = #html_content

    while true do
        -- Find <img tag start
        local img_start = html_content:find("<img", last_pos, true)
        if not img_start then break end

        -- Find end of img tag (next >)
        local img_end = html_content:find(">", img_start)
        if not img_end then break end

        -- Copy everything before this img tag
        table.insert(new_html_parts, html_content:sub(last_pos, img_start - 1))

        -- Extract the img tag
        local img_tag = html_content:sub(img_start, img_end)
        img_idx = img_idx + 1

        -- Replace src with base64 data URL
        local img_info = img_base64_map[img_idx]
        if img_info and img_info.data then
            local data_url = 'src="data:' .. img_info.mime .. ';base64,' .. img_info.data .. '"'
            local new_tag = img_tag:gsub('src="[^"]*"', data_url, 1)
            table.insert(new_html_parts, new_tag)
        else
            -- No downloaded image for this slot, keep original or use placeholder
            table.insert(new_html_parts, img_tag)
        end
        last_pos = img_end + 1
    end

    -- Append remaining content after last img tag
    if last_pos <= html_len then
        table.insert(new_html_parts, html_content:sub(last_pos))
    end

    html_content = table.concat(new_html_parts)

    -- Step 5: Generate full HTML document with large e-ink friendly fonts
    local full_html = '<html>\n'
        .. '<head>\n'
        .. '<meta charset="UTF-8">\n'
        .. '<title>' .. title .. '</title>\n'
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
        os.execute("mkdir -p " .. article_dir)
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

return Zhihu