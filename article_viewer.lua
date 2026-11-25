--[[
    ArticleViewer - Custom popup viewer using ScrollHtmlWidget
    v140: Paged reading. The viewer renders one batch of 5 answers, shows a
    "下一个" link right after the last answer (plus a nav button in the bottom
    status line) and asks main.lua to load the next batch. Link taps are
    routed through ScrollHtmlWidget's html_link_tapped_callback.
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

local logger = require("logger")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
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
local BD = require("ui/bidi")
local _ = require("gettext")
local T = require("ffi/util").template

-- v131: height reserved for the bottom status line
local STATUS_HEIGHT = Screen:scaleBySize(28)

-- v147: the <img> metadata is not trustworthy (Zhihu tags plenty of real
-- photographs with data-rawwidth <= 160, and several answers ship no width at
-- all), so the painted size must come from the bitmap that actually landed on
-- disk. Header parsing only: no decode, no extra RAM.
local pixel_w_cache = {}
local function imagePixelWidth(path)
    local cached = pixel_w_cache[path]
    if cached then return cached end
    local w
    local f = io.open(path, "rb")
    if f then
        local head = f:read(64) or ""
        f:close()
        if head:sub(1, 8) == "\137PNG\r\n\26\n" then
            local b1, b2, b3, b4 = head:byte(17), head:byte(18), head:byte(19), head:byte(20)
            if b1 and b4 then w = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4 end
        elseif head:sub(1, 3) == "GIF" then
            local b1, b2 = head:byte(7), head:byte(8)
            if b1 and b2 then w = b1 + b2 * 256 end
        elseif head:sub(1, 2) == "\255\216" then
            -- JPEG: walk the segment chain up to the first SOF marker
            local fh = io.open(path, "rb")
            if fh then
                fh:read(2)
                while true do
                    local mk = fh:read(2)
                    if not mk or #mk < 2 then break end
                    local m1, m2 = mk:byte(1), mk:byte(2)
                    if m1 ~= 255 then break end
                    if m2 == 216 or m2 == 217 or m2 == 1 or (m2 >= 208 and m2 <= 215) then
                        -- standalone marker: no payload to skip
                    else
                        local lenb = fh:read(2)
                        if not lenb or #lenb < 2 then break end
                        local seglen = lenb:byte(1) * 256 + lenb:byte(2)
                        local is_sof = (m2 >= 192 and m2 <= 195)
                            or (m2 >= 197 and m2 <= 199)
                            or (m2 >= 201 and m2 <= 203)
                            or (m2 >= 205 and m2 <= 207)
                        if is_sof then
                            fh:read(1) -- sample precision
                            local hw = fh:read(4)
                            if hw and #hw == 4 then
                                w = hw:byte(3) * 256 + hw:byte(4)
                            end
                            break
                        end
                        if seglen < 2 then break end
                        fh:read(seglen - 2)
                    end
                end
                fh:close()
            end
        end
    end
    if type(w) ~= "number" or w <= 0 then return nil end
    pixel_w_cache[path] = w
    return w
end

local ArticleViewer = InputContainer:extend{
    name = "article_viewer",
    html_content = "",
    css = "",
    image_dir = nil,
    -- v148: give every content picture a page of its own (opt-in setting)
    image_page_break = false,
    font_size = 22,
    -- v122: Async image loading fields
    full_html = nil,       -- Original HTML with remote img URLs
    pending_urls = nil,    -- List of {url=url, index=i} to download
    article_dir = nil,     -- Per-article cache directory
    plugin = nil,          -- Reference to main Zhihu plugin
    image_map = nil,       -- url -> cached local filename (so cached imgs survive refresh)
    -- v140: batch navigation
    has_next_page = false,
    has_prev_page = false,
    on_next_page = nil,
    on_prev_page = nil,
    _closed = false,
    _downloading = false,
    -- v131: bottom status line state (text is only painted on page changes)
    _status_text = "",     -- latest progress text (not necessarily painted)
    _page_text = "",       -- "12/34" page indicator
    _status_shown = nil,   -- text currently on screen
    _status_page = nil,    -- page number when the status was last painted
}

-- v140: human readable nav target, used for both the status bar button and
-- the tappable HTML link at the end of the batch.
function ArticleViewer:_nextLabel()
    if self.has_next_page then
        return _("下一个 >")
    elseif self.has_prev_page then
        return _("< 上一批")
    end
    return nil
end

function ArticleViewer:_refreshNavButton()
    self:_paintStatus()
end

-- v140: single entry point for the bottom strip and the in-page anchor.
-- _navigating guards against a double trigger (link tap + gesture tap) while
-- the current viewer is being torn down.
function ArticleViewer:_requestNav(dir)
    if self._navigating then return true end
    if dir > 0 then
        if self.has_next_page and self.on_next_page then
            self._navigating = true
            local handler = self.on_next_page
            UIManager:nextTick(function() handler() end)
            return true
        end
    else
        if self.has_prev_page and self.on_prev_page then
            self._navigating = true
            local handler = self.on_prev_page
            UIManager:nextTick(function() handler() end)
            return true
        end
    end
    return false
end

-- v140: link callback for the "下一个" / "上一批" anchors. Current KOReader
-- builds hand over a CREngine link table (external links carry .uri), older
-- ones a plain string: accept both.
function ArticleViewer:_onHtmlLinkTapped(link)
    local uri = link
    if type(link) == "table" then
        uri = link.uri or link.link or link.href
    end
    if type(uri) ~= "string" then return false end
    if uri:match("^zhihu://next") then
        return self:_requestNav(1)
    elseif uri:match("^zhihu://prev") then
        return self:_requestNav(-1)
    end
    return false
end

-- v131: Remember the progress text WITHOUT repainting (e-ink stays calm).
function ArticleViewer:_setStatus(text)
    self._status_text = text or ""
end

function ArticleViewer:_statusLine()
    local parts = {}
    if self._page_text and self._page_text ~= "" then
        table.insert(parts, self._page_text)
    end
    if self._status_text and self._status_text ~= "" then
        table.insert(parts, self._status_text)
    end
    -- v140: the batch nav target sits in the same line, so the strip never
    -- grows taller than STATUS_HEIGHT and never pushes the text around.
    local label = self:_nextLabel()
    if label then
        table.insert(parts, "[" .. label .. "]")
    end
    return table.concat(parts, "   ")
end

-- v131: Paint the status line if its text changed. Called on page turns only.
function ArticleViewer:_paintStatus()
    if not self.status_widget then return end
    local line = self:_statusLine()
    if line == self._status_shown then return end
    self._status_shown = line
    pcall(function()
        self.status_widget:setText(line)
        if self.status_widget.resetLayout then self.status_widget:resetLayout() end
    end)
    UIManager:setDirty(self, "ui")
end

-- v131: Repaint only when the reader has actually turned a page.
function ArticleViewer:_paintStatusOnPageChange()
    local page, count = nil, nil
    pcall(function()
        page = self.html_widget.htmlbox_widget.page_number
        count = self.html_widget.htmlbox_widget.page_count
    end)
    if page and page ~= self._status_page then
        self._status_page = page
        if count and count > 0 then
            self._page_text = string.format("%d/%d", page, count)
        else
            self._page_text = tostring(page)
        end
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

    -- v140: intercept zhihu://next | zhihu://prev anchors. Older KOReader
    -- builds simply ignore an unknown argument, so this stays harmless there.
    scroll_args.html_link_tapped_callback = function(link)
        return self:_onHtmlLinkTapped(link)
    end

    self.html_widget = ScrollHtmlWidget:new(scroll_args)

    -- Override ScrollHtmlWidget's onScrollText: at a page boundary load the
    -- neighbouring batch (v140) or close the viewer (as before).
    local orig_onScrollText = self.html_widget.onScrollText
    self.html_widget.onScrollText = function(html_widget, arg, ges)
        local hb = html_widget.htmlbox_widget
        if not hb then
            return orig_onScrollText(html_widget, arg, ges)
        end
        -- v131: reading/paging stays available while images download in the
        -- background (the content is only swapped once, at the very end).
        if ges.direction == "north" then
            if hb.page_number >= hb.page_count then
                if self:_requestNav(1) then return true end
                UIManager:setDirty(html_widget.dialog, "full")
                local dialog = html_widget.dialog
                UIManager:nextTick(function()
                    if dialog then UIManager:close(dialog) end
                end)
                return true
            end
        elseif ges.direction == "south" then
            if hb.page_number <= 1 then
                if self:_requestNav(-1) then return true end
                UIManager:setDirty(html_widget.dialog, "full")
                local dialog = html_widget.dialog
                UIManager:nextTick(function()
                    if dialog then UIManager:close(dialog) end
                end)
                return true
            end
        end
        local result = orig_onScrollText(html_widget, arg, ges)
        -- v146: a picture that landed on this very page while the reader was
        -- paging was deliberately not swapped in (a relayout mid-turn looks
        -- like a stutter); do it now that the turn is over. No-op when the page
        -- on screen is already up to date.
        if self._applyPendingImages then pcall(self._applyPendingImages) end
        UIManager:setDirty(self, "full")
        -- v131: refresh the bottom progress line only when we page
        self:_paintStatusOnPageChange()
        return result
    end

    -- v140: tapping (instead of swiping) must reach the neighbouring batch
    -- too: right half on the last page -> next batch, left half on the first
    -- page -> previous batch. Inside the document the stock behaviour stays.
    local orig_onTapScrollText = self.html_widget.onTapScrollText
    self.html_widget.onTapScrollText = function(html_widget, arg, ges)
        if not html_widget.htmlbox_widget then
            return orig_onTapScrollText(html_widget, arg, ges)
        end
        -- remember the page so a tap that did move can be told apart from a
        -- tap that hit a boundary (stock handler returns nothing there).
        local before = html_widget.htmlbox_widget.page_number
        local res = orig_onTapScrollText(html_widget, arg, ges)
        if res then
            UIManager:setDirty(self, "full")
            self:_paintStatusOnPageChange()
            return res
        end
        if ges and ges.pos and before == html_widget.htmlbox_widget.page_number then
            local forward = not BD.flipIfMirroredUILayout(ges.pos.x < Screen:getWidth() / 2)
            if forward then
                if self:_requestNav(1) then return true end
            else
                if self:_requestNav(-1) then return true end
            end
        end
        self:_paintStatusOnPageChange()
        return res
    end

    -- v131: slim status line at the bottom of the screen (never over text)
    self.status_widget = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", Screen:scaleBySize(15)),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = screen_w - Screen:scaleBySize(24),
    }

    -- v140: one centred status line ("3/9  [下一个 >]"). Tapping the bottom
    -- strip (or the in-page anchor) loads the next batch.
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
        self.nav_button = nil
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
        -- v140: no full-screen Swipe handler here. Swipes belong to
        -- ScrollHtmlWidget (page turns); registering one at this level used to
        -- close the viewer instead of turning the page.
        self.ges_events = {
            -- v140: tap on the bottom strip only. The article body keeps its
            -- own tap zone inside ScrollHtmlWidget, so page tapping still
            -- works and nothing is stolen from the reader.
            TapStatusBar = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = screen_h - STATUS_HEIGHT,
                        w = screen_w, h = STATUS_HEIGHT,
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
    self:_paintStatusOnPageChange()
    self:_refreshNavButton()

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
        -- v143: fresh throttle state for this viewing session
        self._refresh_pending = nil
        -- v146: the html currently on screen (starts as the placeholder version)
        self._applied_html = nil
        local client = self.plugin.client
        local article_dir = self.article_dir
        local full_html = self.full_html
        local url_to_file = {}
        local queue = self.pending_urls
        table.sort(queue, function(a, b)
            return (a.index or 0) < (b.index or 0)
        end)
        -- v146: the document we start from keeps every picture that is not on
        -- disk yet as a dashed "[图片N]" placeholder. The old code rebuilt the
        -- page from the remote-URL version on every refresh, which collapsed
        -- all those placeholders at once: the reader's page jumped away, the
        -- pictures that did land were somewhere else, and the only thing that
        -- ever looked like a refresh was the very last one. Now each picture is
        -- dropped into the exact slot its own placeholder occupies, so it shows
        -- up where the reader is looking, the moment it lands.
        local base_html = self.html_content or full_html
        local img_tags = {}
        do
            local i = 0
            full_html:gsub("<img([^>]*)>", function(attrs)
                -- v151: avatars are not numbered pictures — skipping them keeps
                -- the numbering aligned with the [图片N] placeholders.
                if attrs:find('class="avatar"', 1, true) then return nil end
                i = i + 1
                img_tags[i] = attrs
            end)
        end
        -- picture number -> local file / remote url
        local by_index = {}
        local url_by_index = {}
        for _, it in ipairs(queue) do
            local n = it.index or 0
            url_by_index[n] = it.url
        end
        local total_count = #queue
        local downloaded_count = 0
        local screen_w = Screen:getWidth()
        -- v150: the text column is inset by the page margin on both sides, so
        -- a picture sized to the raw screen width was wider than the column.
        -- crengine then left-aligned it and the right edge ran past the right
        -- margin (reported as "the picture still leans to the right"). Reserve
        -- a symmetric side margin instead: 7% of the screen, never below
        -- scaleBySize(10), which keeps the picture inside the column and
        -- leaves room for the centring to be visible.
        local side_margin = math.floor(screen_w * 0.07)
        local min_margin = Screen:scaleBySize(10)
        if side_margin < min_margin then side_margin = min_margin end
        local img_target_w = screen_w - 2 * side_margin
        -- v150: trust the real column width when crengine exposes it; the
        -- estimate above is only a fallback.
        do
            local hb = self.html_widget and self.html_widget.htmlbox_widget
            local doc = hb and (hb._document or hb.document or hb.doc)
            if doc and doc.getPageWidth then
                local ok_w, col_w = pcall(function() return doc:getPageWidth() end)
                if ok_w and type(col_w) == "number" and col_w > 0
                        and col_w > screen_w * 0.5
                        and col_w < img_target_w then
                    img_target_w = col_w - Screen:scaleBySize(2)
                end
            end
        end
        if img_target_w <= 0 then img_target_w = screen_w end

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
            if not w or not h or w <= 0 or h <= 0 then
                pcall(function() bb:free() end)
                return false
            end
            -- v141: decide once whether the bitmap must be re-sized to the
            -- text column. Downscale big photos as before; also upscale the
            -- mid-size pictures (Zhihu serves plenty of ~690px images) that
            -- used to render at 60% of the screen width. Only up to 2x, and
            -- never for emoji-sized bitmaps - blowing those up just produces
            -- mush.
            local target
            if w > img_target_w then
                target = img_target_w
            elseif w > 120 then
                -- v147: a real picture, not an icon. Never leave it at a
                -- sliver of the screen just because the source is low-res:
                -- aim for twice the source width, and at least ~55% of the
                -- text column, capped at the column width.
                local floor_w = math.floor(img_target_w * 0.55)
                target = math.max(w * 2, floor_w)
                if target > img_target_w then target = img_target_w end
                if target < w then target = nil end
            end
            if not target then
                -- Already the right size (or an icon / sticker): keep original.
                pcall(function() bb:free() end)
                return false
            end
            local new_h = math.max(1, math.floor(h * target / w))
            local s_ok, scaled = pcall(function()
                return RenderImage:scaleBlitBuffer(bb, target, new_h)
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
        local function ensureImage(url, idx)
            local ext = url:match("%.(%w+)[?]") or url:match("%.(%w+)$") or "jpg"
            local png_name = string.format("img_%03d.png", idx)
            local png_path = article_dir .. png_name
            if (fileSize(png_path) or 0) > 0 then
                return png_name
            end
            local orig_name = string.format("img_%03d.%s", idx, ext)
            local orig_path = article_dir .. orig_name
            if (fileSize(orig_path) or 0) > 0 then
                if downscaleTo(orig_path, png_path) then
                    if orig_path ~= png_path then
                        pcall(function() os.remove(orig_path) end)
                    end
                    return png_name
                end
                return orig_name
            end
            -- Not cached yet: download exactly once
            local dl_ok, dl_result = pcall(function()
                return client:_downloadImage(url, orig_path)
            end)
            if not (dl_ok and dl_result and (fileSize(orig_path) or 0) > 0) then
                return nil
            end
            if downscaleTo(orig_path, png_path) then
                if orig_path ~= png_path then
                    pcall(function() os.remove(orig_path) end)
                end
                return png_name
            end
            return orig_name
        end

        -- v146: image-by-image refresh ---------------------------------
        -- crengine still gives us no way to repaint a single <img> box, so a
        -- relayout is unavoidable. What we can avoid is *rebuilding the whole
        -- page*: buildHtml() starts from the placeholder document and swaps in
        -- only the pictures that are already on disk, one slot at a time.
        local function buildHtml()
            local html = base_html
            -- cached pictures (shipped local by main.lua) as a safety net
            if self.image_map then
                for u, fn in pairs(self.image_map) do
                    local esc = u:gsub("([%%%.%-%+%[%]%(%)%*%?%^%$])", "%%%1")
                    html = html:gsub('src="' .. esc .. '"',
                        function() return 'src="' .. fn .. '"' end)
                end
            end
            for i, attrs in ipairs(img_tags) do
                local fn = by_index[i]
                if fn then
                    local tag = "<img" .. attrs:gsub('src="[^"]*"', 'src="' .. fn .. '"') .. ">"
                    local slot = '<div class="img%-placeholder"><span class="img%-num">%[图片'
                        .. i .. '%]</span></div>'
                    local n
                    html, n = html:gsub(slot, function() return tag end)
                    if n == 0 then
                        -- unexpected markup (no matching placeholder): fall back
                        -- to swapping the remote url wherever it still appears
                        local url = url_by_index[i]
                        if url and url ~= "" then
                            local esc = url:gsub("([%%%.%-%+%[%]%(%)%*%?%^%$])", "%%%1")
                            html = html:gsub('src="' .. esc .. '"',
                                function() return 'src="' .. fn .. '"' end)
                        end
                    end
                end
            end

            -- v147: final say on the painted width comes from the bitmap on
            -- disk, not from the <img> metadata. Any picture the source marks
            -- as "tiny" (data-rawwidth <= 160) but which is a real photo gets
            -- the text column width; only genuine emoji / icons stay small.
            html = html:gsub('<img([^>]*)>', function(attrs)
                -- v151: the avatar keeps the heading-sized box from the
                -- stylesheet; sizing it like a content picture would blow it up
                if attrs:find('class="avatar"', 1, true) then return nil end
                local src = attrs:match('src="([^"]*)"')
                if not src or src:match("^https?://") then return nil end
                local path = src
                if not path:find("/", 1, true) then
                    path = (self.image_dir or article_dir or "") .. path
                end
                local rw = imagePixelWidth(path)
                if not rw then return nil end
                if rw <= 120 then
                    -- genuine emoji / inline icon: keep the intrinsic size
                    if attrs:find("tiny%-img") then return nil end
                    return '<img src="' .. src .. '" class="tiny-img"/>'
                end
                -- real picture: fill the column, but never upscale a low-res
                -- source more than ~2x unless that still leaves it tiny
                local target = math.floor(img_target_w * 0.55)
                if rw * 2 > target then target = rw * 2 end
                if target > img_target_w then target = img_target_w end
                if rw < 300 then
                    -- low-res source: worth a line in crash.log when the reader
                    -- complains again, so we know it is the picture, not us
                    logger.info("zhihu: low-res picture", path, rw, "->", target)
                end
                -- v149: every content picture sits in its own centred block.
                -- Inheriting the paragraph indent was what pushed pictures to
                -- the right; the block also provides the vertical breathing room.
                local cls = "img-block"
                if self.image_page_break then cls = "img-block page-img" end
                -- v150: the picture stays inline (style + stylesheet rule) so
                -- the container's text-align can centre it; a block box would
                -- ignore text-align and hug the left edge again.
                return '<div class="' .. cls .. '"><img src="' .. src
                    .. '" width="' .. tostring(target)
                    .. '" class="full-img" style="display:inline;margin:0 auto;"/></div>'
            end)
            return html
        end

        local function applyImages(final)
            if self._closed then return end
            -- cheap guard: nothing new landed since the last pass
            if not final and (self._applied_count or -1) == downloaded_count then
                return
            end
            self._applied_count = downloaded_count
            local new_html = buildHtml()
            if final then
                -- whatever is still remote by now is a failed download
                new_html = new_html:gsub('<img([^>]*)>', function(attrs)
                    local url = attrs:match('src="([^"]*)"')
                    if url and url:match("^https?://") then
                        return '<div class="img-placeholder"><span class="img-num">[图片]</span></div>'
                    end
                    return nil
                end)
            end

            -- nothing on disk changed since the last paint: do not touch the
            -- screen at all (this is what keeps page turns uninterrupted)
            if new_html == self._applied_html then return end
            self._applied_html = new_html

            -- v145: never swallow a layout failure silently — without this a
            -- broken refresh looks exactly like "images downloaded, screen did
            -- not move" and there is nothing in the log to go on.
            local ok, err = pcall(function()
                local hb = self.html_widget.htmlbox_widget
                if not hb then return end
                local cur = hb.page_number
                hb:setContent(
                    new_html, self.css,
                    Screen:scaleBySize(self.font_size),
                    true, nil, article_dir
                )
                -- the layout changed under our feet: stay where the reader is
                -- and never park him on a page number that no longer exists
                if hb.page_count > 0 then
                    if cur and cur > hb.page_count then cur = hb.page_count end
                    if cur and cur ~= hb.page_number then hb:setPageNumber(cur) end
                end
                local sb = self.html_widget.v_scroll_bar
                if sb then sb.enable = hb.page_count > 1 end
                if self.html_widget._updateScrollBar then
                    pcall(function() self.html_widget:_updateScrollBar() end)
                end
            end)
            if not ok then
                logger.warn("zhihu: image refresh failed:", err)
            end

            self._status_page = nil
            self:_paintStatusOnPageChange()
            -- v145: ScrollHtmlWidget has no registered dimen of its own, so a
            -- setDirty aimed at it is silently dropped and the new layout never
            -- reaches the screen. Dirty the viewer itself, and the inner dialog
            -- as a belt-and-braces measure.
            -- v146: an intermediate pass uses "partial". A "full" e-ink refresh
            -- takes around a second on a Kindle, so back-to-back full refreshes
            -- get merged by the driver and the reader only ever sees one jump at
            -- the end — exactly the "all pictures appear at once" symptom. A
            -- partial refresh is what an in-place picture swap wants; the last
            -- pass still asks for a full one to clean up the ghosting.
            local mode = final and "full" or "partial"
            UIManager:setDirty(self, mode)
            local dlg = self.html_widget and self.html_widget.dialog
            if dlg then UIManager:setDirty(dlg, mode) end
        end

        -- v146: exposed for the page-turn hooks above, so a swap that was held
        -- back during navigation happens as soon as the turn finishes
        self._applyPendingImages = function() applyImages(false) end

        local function scheduleImageRefresh()
            if self._closed then return end
            -- one relayout per landed picture; a picture that finishes while a
            -- refresh is already on its way rides along with it
            if self._refresh_pending then return end
            self._refresh_pending = true
            local tries = 0
            local function fire()
                if self._closed then
                    self._refresh_pending = false
                    return
                end
                tries = tries + 1
                -- do not hijack the screen while the reader turns a page, but
                -- never wait forever either (a finished batch is a dead end)
                if self._navigating and tries < 3 then
                    UIManager:scheduleIn(0.3, fire)
                    return
                end
                self._refresh_pending = false
                applyImages(false)
            end
            -- short delay: the picture is already on disk, it only has to be
            -- laid out — anything longer reads as "nothing happens"
            UIManager:scheduleIn(0.1, fire)
        end

        local function downloadOne(index)
            if self._closed then
                setProgress(nil)
                return
            end
            if index > total_count then
                if self._closed then
                    setProgress(nil)
                    return
                end
                self._downloading = false
                setProgress(nil)
                -- v143: last pass — placeholders for the pictures we lost
                applyImages(true)
                -- v131: download finished — clear the status line and draw it
                self:_paintStatus()
                return
            end

            local item = queue[index]

            -- v131: update the counter in memory only (no screen refresh here)
            setProgress(T(_("Images: %1/%2"), index, total_count))

            local filename = ensureImage(item.url, item.index)
            if filename then
                url_to_file[item.url] = filename
                -- v146: remember which picture number this file belongs to, so
                -- it can be dropped into that very placeholder
                by_index[item.index or 0] = filename
                downloaded_count = downloaded_count + 1
                -- this picture is on disk — put it on the page right away,
                -- no matter how many pictures are still queued behind it
                scheduleImageRefresh()
            end

            -- v131: only repaint if the reader has turned a page meanwhile
            self:_paintStatusOnPageChange()

            UIManager:scheduleIn(0.2, function()
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

-- v140: UIManager:close() does not go through onClose(), so the teardown work
-- has to live here as well: otherwise the background image downloader keeps
-- writing into an already closed widget (wasted work on a dead layout) and the
-- plugin keeps a reference to a viewer that no longer exists.
function ArticleViewer:onCloseWidget()
    self._closed = true
    if self.plugin and self.plugin.current_viewer == self then
        self.plugin.current_viewer = nil
    end
    self._setProgress = nil
    if self.status_widget and self.status_widget.free then
        pcall(function() self.status_widget:free() end)
    end
    self.status_widget = nil
end

function ArticleViewer:onClose()
    self._closed = true
    if self.plugin and self.plugin.current_viewer == self then
        self.plugin.current_viewer = nil
    end
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

-- v140: the bottom strip is a single tap target: load the next batch when one
-- exists, otherwise go back to the previous batch. Closing stays on the
-- gesture/key paths (swipe past the last/first page, Back key, Home).
function ArticleViewer:onTapStatusBar(arg, ges)
    if self:_requestNav(self.has_next_page and 1 or -1) then
        return true
    end
    if self.has_next_page == false and self.has_prev_page then
        return self:_requestNav(-1)
    end
    -- Swallow the tap: the point is already the navigation strip, it must not
    -- page the article body behind it.
    return true
end

return ArticleViewer
