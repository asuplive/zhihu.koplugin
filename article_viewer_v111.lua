--[[
    ArticleViewer - Custom popup viewer using ScrollHtmlWidget
    v89: Fix onClose to actually close widget with nextTick
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

    -- Full-screen white background container with ScrollHtmlWidget
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
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

function ArticleViewer:onClose()
    UIManager:setDirty(self, "full")
    local obj = self
    UIManager:nextTick(function()
        UIManager:close(obj)
    end)
    return true
end

function ArticleViewer:onSwipe(arg, ges_ev)
    if ges_ev.direction == "north" or ges_ev.direction == "south" then
        UIManager:setDirty(self, "full")
        local obj = self
        UIManager:nextTick(function()
            UIManager:close(obj)
        end)
        return true
    end
    return false
end

function ArticleViewer:onShow()
    UIManager:setDirty(self, "full")
    return true
end

return ArticleViewer
