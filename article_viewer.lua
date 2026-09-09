--[[
    ArticleViewer - Custom popup viewer using ScrollHtmlWidget
    v131: Progress is shown in a slim status line at the BOTTOM (it no longer
    covers the text) and is only repainted when the page changes, so e-ink
    does not flicker on every single image. Reading/paging is allowed while
    images download in the background.
    v130: ALL images load (no count/size caps). Large images are downscaled
    to screen width after download so the total decoded memory stays bounded
    on slow e-ink devices.
    v129: placeholder fallback for images that could not be loaded.
    v122: Text-first with per-article cache.
    Images downloaded in background; in-place setContent refresh when all done.
]]

local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local _ = require("gettext")
local T = require("ffi/util").template

-- v131: height reserved for the bottom status line
local STATUS_HEIGHT = Screen:scaleBySize(22)

local ArticleViewer = InputContainer:extend{
    name = "article_viewer",
    html_content = "",
    css = "",
    image_dir = nil,
    font_size = 22,
    -- v122: Async image loading fields
    full_html = nil,       -- Original HTML with remote img URLs
    pending_urls = nil,    -- List of {url=url, index=i} to download
    article_dir = nil,     -- Per-article cache directory
    plugin = nil,          -- Reference to main Zhihu plugin
    image_map = nil,       -- url -> cached local filename (so cached imgs survive refresh)
    _closed = false,
    _downloading = false,
    -- v131: bottom status line state (text is only painted on page changes)
    _status_text = "",     -- latest progress text (not necessarily painted)
    _status_shown = nil,   -- text currently on screen
    _status_page = nil,    -- page number when the status was last painted
}

-- v131: Remember the progress text WITHOUT repainting (e-ink stays calm).
function ArticleViewer:_setStatus(text)
    self._status_text = text or ""
end

-- v131: Paint the status line if its text changed. Called on page turns only.
function ArticleViewer:_paintStatus()
    if not self.status_widget or not self.status_bar then return end
    if self._status_text == self._status_shown then return end
    self._status_shown = self._status_text
    pcall(function()
        self.status_widget:setText(self._status_text)
        if self.status_bar.resetLayout then self.status_bar:resetLayout() end
    end)
    UIManager:setDirty(self, "ui")
end

-- v131: Repaint only when the reader has actually turned a page.
function ArticleViewer:_paintStatusOnPageChange()
    local page = nil
    pcall(function()
        page = self.html_widget.htmlbox_widget.page_number
    end)
    if page and page ~= self._status_page then
        self._status_page = page
        self:_paintStatus()
    end
end

function ArticleViewer:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local scroll_args = {
        html_body = self.html_content,
        css = self.css,
        is_xhtml = true,
        default_font_size = Screen:scaleBySize(self.font_size),
        width = screen_w,
        -- v131: leave room for the bottom status line so it never covers text
        height = screen_h - STATUS_HEIGHT,
        dialog = self,
        scroll_bar_width = Screen:scaleBySize(6),
        text_scroll_span = Screen:scaleBySize(4),
    }

    if self.image_dir and self.image_dir ~= "" then
        scroll_args.html_resource_directory = self.image_dir
    end

    self.html_widget = ScrollHtmlWidget:new(scroll_args)

    -- Override ScrollHtmlWidget's onScrollText: close dialog at page boundaries
    local orig_onScrollText = self.html_widget.onScrollText
    self.html_widget.onScrollText = function(html_widget, arg, ges)
        -- v131: reading/paging stays available while images download in the
        -- background (the content is only swapped once, at the very end).
        if ges.direction == "north" then
            if html_widget.htmlbox_widget.page_number >= html_widget.htmlbox_widget.page_count then
                orig_onScrollText(html_widget, arg, ges)
                UIManager:setDirty(html_widget.dialog, "full")
                local dialog = html_widget.dialog
                UIManager:nextTick(function()
                    if dialog then UIManager:close(dialog) end
                end)
                return true
            end
        elseif ges.direction == "south" then
            if html_widget.htmlbox_widget.page_number <= 1 then
                orig_onScrollText(html_widget, arg, ges)
                UIManager:setDirty(html_widget.dialog, "full")
                local dialog = html_widget.dialog
                UIManager:nextTick(function()
                    if dialog then UIManager:close(dialog) end
                end)
                return true
            end
        end
        local result = orig_onScrollText(html_widget, arg, ges)
        UIManager:setDirty(self, "full")
        -- v131: refresh the bottom progress line only when we page
        self:_paintStatusOnPageChange()
        return result
    end

    -- v131: slim status line at the bottom of the screen (never over text)
    self.status_widget = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", Screen:scaleBySize(15)),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.status_bar = CenterContainer:new{
        dimen = Geom:new{w = screen_w, h = STATUS_HEIGHT},
        self.status_widget,
    }

    local ok_layout = pcall(function()
        self[1] = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{w = screen_w, h = screen_h},
            VerticalGroup:new{
                self.html_widget,
                self.status_bar,
            },
        }
    end)
    if not ok_layout then
        -- Fallback: plain full-height article (progress then stays hidden)
        self.status_widget = nil
        self.status_bar = nil
        self[1] = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{w = screen_w, h = screen_h},
            self.html_widget,
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = {{"Back"}, doc = "close article viewer"},
        }
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = screen_w,
                        h = screen_h,
                    }
                }
            },
        }
    end
end

-- v129: Return a file's size, or nil if it does not exist.
local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end") or 0
    f:close()
    return size
end

function ArticleViewer:onShow()
    UIManager:setDirty(self, "full")

    -- v131: progress lives in the bottom status line, not in a popup that
    -- covers the article. Nothing is repainted per image — the counter is
    -- only drawn when the reader turns a page (see _paintStatusOnPageChange).
    local function setProgress(text)
        self:_setStatus(text or "")
    end
    self._setProgress = setProgress

    -- v122: Background download with in-place setContent refresh
    if self.pending_urls and #self.pending_urls > 0 and self.plugin then
        self._downloading = true
        local client = self.plugin.client
        local article_dir = self.article_dir
        local full_html = self.full_html
        local url_to_file = {}
        local total_count = #self.pending_urls
        local downloaded_count = 0
        local screen_w = Screen:getWidth()

        -- v130: shrink an image to screen width. A full-resolution photo can
        -- decode to tens of MB of RAM — the Kindle freeze — while a
        -- screen-width copy decodes to ~2MB and looks identical on a
        -- 6-inch e-ink screen. Returns true when png_path was written.
        local function downscaleTo(orig_path, png_path)
            local ok, bb = pcall(function()
                return RenderImage:renderImageFile(orig_path)
            end)
            if not ok or not bb then return false end
            local w, h = bb:getWidth(), bb:getHeight()
            if not w or not h or w <= 0 or h <= 0 or w <= screen_w then
                -- Already small enough (or unreadable): keep the original.
                pcall(function() bb:free() end)
                return false
            end
            local new_h = math.max(1, math.floor(h * screen_w / w))
            local s_ok, scaled = pcall(function()
                return RenderImage:scaleBlitBuffer(bb, screen_w, new_h)
            end)
            pcall(function() bb:free() end)
            if not s_ok or not scaled then return false end
            local w_ok = pcall(function()
                return scaled:writePng(png_path)
            end)
            pcall(function() scaled:free() end)
            if not w_ok then
                pcall(function() os.remove(png_path) end)
                return false
            end
            return true
        end

        -- v132: make sure the image exists locally — every image is loaded
        -- (no caps) and is cached in the article folder, so a second visit
        -- never downloads it again (main.lua renders cached files directly).
        -- Cache names: the downscaled screen-width PNG is preferred; the
        -- original-extension file is kept as a cache when downscaling is not
        -- possible (or not needed). Returns the filename, or nil on failure.
        local function ensureImage(url, idx)
            local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
            local png_name = string.format("img_%03d.png", idx)
            local png_path = article_dir .. png_name
            -- v132: cache hit (treat 0-byte files as missing) — reuse as is
            if (fileSize(png_path) or 0) > 0 then
                return png_name
            end
            local orig_name = string.format("img_%03d.%s", idx, ext)
            local orig_path = article_dir .. orig_name
            if (fileSize(orig_path) or 0) > 0 then
                -- Cached in original form (older version, or an image that
                -- was already screen-sized): normalise it once, then keep it.
                if downscaleTo(orig_path, png_path) then
                    -- v132 fix: never delete the cache when both names are
                    -- the same file (happens for ".png" URLs).
                    if orig_path ~= png_path then
                        pcall(function() os.remove(orig_path) end)
                    end
                    return png_name
                end
                return orig_name -- still a valid cache entry
            end
            -- Not cached yet: download exactly once
            local dl_ok, dl_result = pcall(function()
                return client:_downloadImage(url, orig_path)
            end)
            if not (dl_ok and dl_result and (fileSize(orig_path) or 0) > 0) then
                return nil
            end
            -- Freshly downloaded: shrink to screen width when it is bigger
            if downscaleTo(orig_path, png_path) then
                if orig_path ~= png_path then
                    pcall(function() os.remove(orig_path) end)
                end
                return png_name
            end
            return orig_name -- small/unsupported image: keep it as the cache
        end

        local function downloadOne(index)
            if self._closed then
                setProgress(nil)
                return
            end
            if index > total_count then
                -- Double-check _closed before setContent
                if self._closed then
                    setProgress(nil)
                    return
                end
                self._downloading = false
                setProgress(nil)
                if downloaded_count > 0 then
                    local new_html = full_html
                    local function replaceUrl(u, fn)
                        local esc = u:gsub("([%%%.%-%+%[%]%(%)%*%?%^%$])", "%%%1")
                        -- v127 fix: function replacement so "%" in the filename
                        -- is not treated as a magic character by gsub
                        new_html = new_html:gsub('src="' .. esc .. '"',
                            function() return 'src="' .. fn .. '"' end)
                    end
                    -- Keep already-cached images (they reference remote URLs in full_html)
                    if self.image_map then
                        for u, fn in pairs(self.image_map) do replaceUrl(u, fn) end
                    end
                    -- Then swap in freshly downloaded pending images
                    for _, item in ipairs(self.pending_urls) do
                        if url_to_file[item.url] then
                            replaceUrl(item.url, url_to_file[item.url])
                        end
                    end
                    -- v129: any <img> still pointing at a remote URL (failed
                    -- or unloaded image) becomes a placeholder instead
                    -- of a broken/blank box after the refresh.
                    new_html = new_html:gsub('<img([^>]*)>', function(attrs)
                        local url = attrs:match('src="([^"]*)"')
                        if url and url:match("^https?://") then
                            return '<div class="img-placeholder"><span class="img-num">[图片]</span></div>'
                        end
                        return nil -- keep local image tags untouched
                    end)

                    -- In-place refresh: keep same widget, update content
                    pcall(function()
                        self.html_widget.htmlbox_widget:setContent(
                            new_html, self.css,
                            Screen:scaleBySize(self.font_size),
                            true, nil, article_dir
                        )
                        UIManager:setDirty(self, "full")
                    end)
                end
                -- v131: download finished — clear the status line and draw it
                self:_paintStatus()
                return
            end

            local item = self.pending_urls[index]

            -- v131: update the counter in memory only (no screen refresh here)
            setProgress(T(_("Images: %1/%2"), index, total_count))

            local filename = ensureImage(item.url, item.index)
            if filename then
                url_to_file[item.url] = filename
                downloaded_count = downloaded_count + 1
            end

            -- v131: only repaint if the reader has turned a page meanwhile
            self:_paintStatusOnPageChange()

            UIManager:scheduleIn(0.3, function()
                downloadOne(index + 1)
            end)
        end

        -- v131: first paint, then only on page turns / when finished
        setProgress(T(_("Images: %1/%2"), 0, total_count))
        self:_paintStatus()

        UIManager:scheduleIn(0.5, function()
            downloadOne(1)
        end)
    end

    return true
end

function ArticleViewer:onClose()
    self._closed = true
    -- v131: make sure the status line does not outlive the viewer
    if self._setProgress then
        pcall(function() self._setProgress(nil) end)
    end
    UIManager:setDirty(self, "full")
    local obj = self
    UIManager:nextTick(function()
        UIManager:close(obj)
    end)
    return true
end

function ArticleViewer:onSwipe(arg, ges_ev)
    -- v131: closing is allowed even while images are still downloading
    -- (the background loop stops on the next tick via _closed).
    if ges_ev.direction == "north" or ges_ev.direction == "south" then
        self._closed = true
        UIManager:setDirty(self, "full")
        local obj = self
        UIManager:nextTick(function()
            UIManager:close(obj)
        end)
        return true
    end
    return false
end

function ArticleViewer:onTap()
    -- v131: taps are no longer swallowed during download, so the reader can
    -- keep turning pages while images load in the background.
    UIManager:nextTick(function()
        if not self._closed then self:_paintStatusOnPageChange() end
    end)
    return false
end

return ArticleViewer
