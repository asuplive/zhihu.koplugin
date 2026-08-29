--[[
    ArticleViewer - Custom popup viewer using ScrollHtmlWidget
    v122: Text-first with per-article cache.
    Images downloaded in background; in-place setContent refresh when all done.
    Interaction blocked during download to prevent race conditions.
]]

local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")

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
    _closed = false,
    _downloading = false,
}

function ArticleViewer:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local scroll_args = {
        html_body = self.html_content,
        css = self.css,
        is_xhtml = true,
        default_font_size = Screen:scaleBySize(self.font_size),
        width = screen_w,
        height = screen_h,
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
        -- Block scroll gestures during download
        if html_widget.dialog and html_widget.dialog._downloading then
            return true
        end
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
        return result
    end

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{w = screen_w, h = screen_h},
        self.html_widget,
    }

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

function ArticleViewer:onShow()
    UIManager:setDirty(self, "full")

    -- v122: Background download with in-place setContent refresh
    if self.pending_urls and #self.pending_urls > 0 and self.plugin then
        self._downloading = true
        local client = self.plugin.client
        local article_dir = self.article_dir
        local full_html = self.full_html
        local url_to_file = {}
        local total_count = #self.pending_urls
        local downloaded_count = 0

        local function downloadOne(index)
            if self._closed then return end
            if index > total_count then
                -- Double-check _closed before setContent
                if self._closed then return end
                self._downloading = false
                if downloaded_count > 0 then
                    local new_html = full_html
                    for _, item in ipairs(self.pending_urls) do
                        local url = item.url
                        local idx = item.index
                        local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
                        if ext == "webp" then ext = "jpg" end
                        local filename = string.format("img_%03d.%s", idx, ext)
                        local esc_url = url:gsub("([%%%.%-%+%[%]%(%)%*%?%^%$])", "%%%1")
                        new_html = new_html:gsub(
                            'src="' .. esc_url .. '"',
                            'src="' .. filename .. '"'
                        )
                    end

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
                return
            end

            local item = self.pending_urls[index]
            local url = item.url
            local idx = item.index
            local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
            if ext == "webp" then ext = "jpg" end
            local filename = string.format("img_%03d.%s", idx, ext)
            local filepath = article_dir .. filename

            local f = io.open(filepath, "rb")
            if f then
                f:close()
                url_to_file[url] = filename
                downloaded_count = downloaded_count + 1
            else
                -- v123: Check _downloadImage return value + verify file exists
                local dl_ok, dl_result = pcall(function()
                    return client:_downloadImage(url, filepath)
                end)
                if dl_ok and dl_result then
                    -- Double-check file was actually written
                    local f2 = io.open(filepath, "rb")
                    if f2 then
                        f2:close()
                        url_to_file[url] = filename
                        downloaded_count = downloaded_count + 1
                    end
                end
            end

            UIManager:scheduleIn(0.3, function()
                downloadOne(index + 1)
            end)
        end

        UIManager:scheduleIn(0.5, function()
            downloadOne(1)
        end)
    end

    return true
end

function ArticleViewer:onClose()
    self._closed = true
    UIManager:setDirty(self, "full")
    local obj = self
    UIManager:nextTick(function()
        UIManager:close(obj)
    end)
    return true
end

function ArticleViewer:onSwipe(arg, ges_ev)
    if self._downloading then
        return true
    end
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
    if self._downloading then
        return true
    end
    return false
end

return ArticleViewer
