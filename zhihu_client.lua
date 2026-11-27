--[[
    Zhihu Client Module for KOReader  (v140)
    - EPUB content generation (HTML format)
    - Synchronous HTTP, robust cookie parsing
    - Paged answer rendering (5 answers per page) with an on-disk page cache
]]

local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")

local json
local ok_json, json_module = pcall(require, "rapidjson")
if ok_json then json = json_module end

local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    .. " (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

local SEPARATOR = string.rep("-", 42)

-- v141: crengine lays an <img> out at its bitmap size and ignores
-- `img { width: 100% }` from the stylesheet, which is why some answers show a
-- postage-stamp picture. Declaring a pixel width on the tag itself is honoured
-- by crengine, so ask the device once for the usable text width.
local Screen
do
    local ok_dev, dev = pcall(require, "device")
    if ok_dev and dev then Screen = dev.screen end
end

local DEFAULT_IMG_WIDTH
local function getRenderImgWidth()
    if DEFAULT_IMG_WIDTH ~= nil then return DEFAULT_IMG_WIDTH end
    local w
    if Screen and Screen.getWidth then
        local ok, sw = pcall(function() return Screen:getWidth() end)
        if ok then w = sw end
    end
    if type(w) ~= "number" or w <= 0 then
        DEFAULT_IMG_WIDTH = false -- unknown: leave the tag untouched
        return false
    end
    -- ScrollHtmlWidget reserves a scroll bar plus a spacer: stay inside the
    -- text column so crengine does not have to shrink the image a second time.
    -- v150: the column is inset by the page margin on *both* sides. Sizing the
    -- picture to the raw screen width made it wider than the column, and the
    -- overflow ran past the right margin (the "picture still leans right"
    -- report). Reserve a symmetric 7% margin, never less than scaleBySize(10),
    -- matching what article_viewer uses as its target width.
    local side = math.floor(w * 0.07)
    local min_side = 16
    if Screen.scaleBySize then
        local ok, m = pcall(function() return Screen:scaleBySize(10) end)
        if ok and type(m) == "number" and m > 0 then min_side = m end
    end
    if side < min_side then side = min_side end
    DEFAULT_IMG_WIDTH = w - 2 * side
    return DEFAULT_IMG_WIDTH
end

-- v140: how many answers are rendered / fetched per page.
local DEFAULT_PAGE_SIZE = 5
-- v140: how long a fetched answer page stays valid in the on-disk cache.
local DEFAULT_CACHE_TTL = 3600
-- v140: upper bound for a single answer's HTML. Longer answers are cut with a
-- hint: one huge answer is what turns page turns into multi-second waits.
local MAX_ANSWER_HTML_BYTES = 120 * 1024

-- =========================================================================
-- Helpers
-- =========================================================================

local function urlDecode(str)
    if not str then return "" end
    str = str:gsub("+", " ")
    str = str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return str
end

local function codepointToUTF8(num)
    if num < 128 then return string.char(num) end
    if num < 2048 then
        return string.char(0xC0 + math.floor(num/64), 0x80 + (num%64))
    end
    if num < 65536 then
        return string.char(0xE0 + math.floor(num/4096),
            0x80 + (math.floor(num/64)%64), 0x80 + (num%64))
    end
    return ""
end

local function htmlToText(html, keep_images)
    if not html or html == "" then return "", {} end
    local image_list = {}
    -- Extract image URLs BEFORE removing noscript (zhihu wraps imgs in noscript)
    if keep_images then
        local seen_urls = {}
        html = html:gsub("<noscript[^>]*>", "")
        html = html:gsub("</noscript>", "")
        local img_count = 0
        html = html:gsub("<img[^>]*>", function(tag)
            img_count = img_count + 1
            local url = nil
            local s = tag:find('data-actualsrc="', 1, true)
            if s then
                local e = tag:find('"', s + 16, true)
                if e then url = tag:sub(s + 16, e - 1) end
            end
            if not url or url == "" then
                s = tag:find(' src="', 1, true)
                if s then
                    local e = tag:find('"', s + 6, true)
                    if e then url = tag:sub(s + 6, e - 1) end
                end
            end
            if url and #url > 0 and not seen_urls[url] then
                seen_urls[url] = true
                table.insert(image_list, url)
            end
            return "[图片" .. img_count .. "]"
        end)
    else
        html = html:gsub("<noscript[^>]*>.-</noscript>", "")
        html = html:gsub("<img[^>]*>", "")
    end
    html = html:gsub("<b>(.-)</b>", "**%1**")
    html = html:gsub("<strong>(.-)</strong>", "**%1**")
    html = html:gsub("<script[^>]*>.-</script>", "")
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<br[^>]*/?>", "\n")
    html = html:gsub("</p>", "\n\n")
    html = html:gsub("</div>", "\n")
    html = html:gsub("</h%d>", "\n\n")
    html = html:gsub("</tr>", "\n")
    html = html:gsub("</blockquote>", "\n\n")
    html = html:gsub("<li[^>]*>", "\n  - ")
    html = html:gsub("</li>", "")
    html = html:gsub("<hr[^>]*/?>", "\n" .. SEPARATOR .. "\n")
    html = html:gsub("</td>", "  ")
    html = html:gsub("</th>", "  ")
    -- v127 fix: include the closing ">" (old pattern "<[^>]+" left stray ">"
    -- characters in the plain text output)
    html = html:gsub("<[^>]*>", "")
    html = html:gsub("&nbsp;", " ")
    html = html:gsub("&lt;", "<")
    html = html:gsub("&gt;", ">")
    html = html:gsub("&quot;", '"')
    html = html:gsub("&#39;", "'")
    html = html:gsub("&apos;", "'")
    html = html:gsub("&hellip;", "...")
    html = html:gsub("&mdash;", "\xE2\x80\x94")
    html = html:gsub("&ndash;", "\xE2\x80\x93")
    html = html:gsub("&ldquo;", "\xE2\x80\x9C")
    html = html:gsub("&rdquo;", "\xE2\x80\x9D")
    html = html:gsub("&lsquo;", "\xE2\x80\x98")
    html = html:gsub("&rsquo;", "\xE2\x80\x99")
    html = html:gsub("&middot;", "\xC2\xB7")
    html = html:gsub("&times;", "\xC3\x97")
    html = html:gsub("&divide;", "\xC3\xB7")
    html = html:gsub("&amp;", "&")
    html = html:gsub("&#(%d+);", function(n) return codepointToUTF8(tonumber(n) or 0) end)
    html = html:gsub("&#x(%x+);", function(n) return codepointToUTF8(tonumber(n, 16) or 0) end)
    html = html:gsub("\n\n\n+", "\n\n")
    html = html:gsub("[ \t]+", " ")
    html = html:gsub(" \n", "\n")
    html = html:gsub("\n ", "\n")
    html = html:gsub("^%s+", "")
    html = html:gsub("%s+$", "")
    return html, image_list
end

local function decodeJSON(text)
    if not text or text == "" then return nil, "empty JSON" end
    if not json then
        local ok_dk, dkjson = pcall(require, "dkjson")
        if ok_dk then json = dkjson
        else return nil, "JSON module unavailable" end
    end
    local ok, result = pcall(json.decode, text)
    if not ok then return nil, "JSON parse error" end
    return result
end

-- Escape XML special characters for EPUB/XHTML
local function escapeXml(text)
    if not text then return "" end
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    text = text:gsub("'", "&apos;")
    return text
end

-- Format Unix timestamp to YYYY-MM-DD HH:MM
local function formatTime(unix_timestamp)
    if not unix_timestamp then return "" end
    -- Convert string to number if needed
    local ts = tonumber(unix_timestamp)
    if not ts then return "" end
    -- os.date may not handle timezone correctly on embedded devices,
    -- but gives a reasonable approximation
    local ok, result = pcall(function()
        return os.date("%Y-%m-%d %H:%M", ts)
    end)
    if ok and result then return result end
    return ""
end

-- Clean HTML content for export: remove scripts/styles, fix images
local function cleanHtmlForEpub(html)
    if not html or html == "" then return "<p>(no content)</p>" end
    html = html:gsub("<script[^>]*>.-</script>", "")
    html = html:gsub("<style[^>]*>.-</style>", "")
    -- Remove entire noscript blocks (zhihu puts duplicate img in noscript)
    html = html:gsub("<noscript[^>]*>.-</noscript>", "")
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<br[^>]*/?>", "<br/>")
    html = html:gsub("<hr[^>]*/?>", "<hr/>")
    -- Fix img tags: copy data-actualsrc to src BEFORE removing data-* attrs
    html = html:gsub("<img([^>]*)>", function(attrs)
        -- Ensure self-closing
        if attrs:sub(-1) ~= "/" then
            attrs = attrs .. "/"
        end
        -- If data-actualsrc exists, use it as src (zhihu lazy-load)
        local actual_src = attrs:match('data%-actualsrc="([^"]*)"')
        if not actual_src then
            actual_src = attrs:match("data%-actualsrc='([^']*)'")
        end
        if actual_src and actual_src ~= "" then
            -- Replace existing src or add new one (use function to avoid % in URL)
            if attrs:find(' src="') then
                attrs = attrs:gsub(' src="[^"]*"', function() return ' src="' .. actual_src .. '"' end)
            elseif attrs:find(" src='") then
                attrs = attrs:gsub(" src='[^']*'", function() return " src='" .. actual_src .. "'" end)
            else
                attrs = ' src="' .. actual_src .. '"' .. attrs
            end
        end
        return "<img" .. attrs .. ">"
    end)
    -- Now safe to remove data-* attributes
    html = html:gsub('%sdata%-[^=]-="[^"]*"', "")
    html = html:gsub("%sdata%-[^=]-='[^']*'", "")
    -- Remove fixed width/height so CSS max-width:100% works properly
    html = html:gsub(' width="%d+"', "")
    html = html:gsub(' width=%d+', "")
    html = html:gsub(' height="%d+"', "")
    html = html:gsub(' height=%d+', "")
    html = html:gsub(" width='%d+'", "")
    html = html:gsub(" height='%d+'", "")
    return html
end

-- =========================================================================
-- v140: Render-oriented HTML cleaning.
--
-- The answers API returns very rich markup: inline `style=`, `class=`,
-- `data-*` attributes, duplicate <noscript> images, <svg> formulas and even
-- <script> blocks. MuPDF (the engine behind ScrollHtmlWidget) builds a DOM
-- node for every one of those, so layout cost grows with the *markup volume*,
-- not with the visible text. Stripping what MuPDF cannot use is what makes a
-- long answer stop feeling sluggish when turned page by page.
--
-- The output is also made strictly XHTML-safe (self-closed empty tags and
-- numeric entities only) so MuPDF can use its fast XML parser instead of
-- silently falling back to the HTML5 (gumbo) parser.
-- =========================================================================

local NAMED_ENTITIES = {
    nbsp = "#160", lt = "#60", gt = "#62", amp = "#38", quot = "#34", apos = "#39",
    hellip = "#8230", mdash = "#8212", ndash = "#8211",
    ldquo = "#8220", rdquo = "#8221", lsquo = "#8216", rsquo = "#8217",
    middot = "#183", times = "#215", divide = "#247", plusmn = "#177",
    copy = "#169", reg = "#174", trade = "#8482", deg = "#176",
    laquo = "#171", raquo = "#187", bull = "#8226",
    prime = "#8242", Prime = "#8243", minus = "#8722",
    sup2 = "#178", sup3 = "#179", frac12 = "#189",
    ensp = "#8194", emsp = "#8195", thinsp = "#8201",
    sect = "#167", para = "#182", euro = "#8364", pound = "#163",
    yen = "#165", cent = "#162", infin = "#8734", ne = "#8800",
    le = "#8804", ge = "#8805",
    larr = "#8592", uarr = "#8593", rarr = "#8594", darr = "#8595", harr = "#8596",
    hearts = "#9829", spades = "#9824", clubs = "#9827", diams = "#9830",
    permil = "#8240", lsaquo = "#8249", rsaquo = "#8250",
}

-- Turn every entity reference into the numeric form MuPDF handles natively and
-- escape the bare ampersands it would otherwise choke on. Unknown *named*
-- entities are dropped instead of being left to derail the parser.
local function normalizeEntities(html)
    if not html or html == "" then return "" end
    local kept = {}
    -- 1. Park every well-formed entity reference so step 2 cannot double-escape it.
    html = html:gsub("&(%#?[%w]+);", function(name)
        kept[#kept + 1] = name
        return "\1" .. #kept .. "\2"
    end)
    -- 2. Escape the remaining bare ampersands.
    html = html:gsub("&", "&amp;")
    -- 3. Restore: numeric stays numeric, known names become numeric, rest dropped.
    html = html:gsub("\1(%d+)\2", function(idx)
        local name = kept[tonumber(idx)]
        if not name or name == "" then return "" end
        if name:sub(1, 1) == "#" then
            return "&" .. name .. ";"
        end
        local num = NAMED_ENTITIES[name]
        if num then
            return "&" .. num .. ";"
        end
        return ""
    end)
    return html
end

-- Reduce one answer body to the minimum markup MuPDF renders safely.
local function cleanHtmlForRender(html)
    if not html or html == "" then return "" end

    -- 1. Blocks MuPDF cannot render, or that only duplicate content.
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<script[^>]*>.-</script>", "")
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub("<noscript[^>]*>.-</noscript>", "")
    html = html:gsub("<iframe[^>]*>.-</iframe>", "")
    html = html:gsub("<video[^>]*>.-</video>", "")
    html = html:gsub("<audio[^>]*>.-</audio>", "")
    -- Inline SVG (LaTeX formulas) renders as garbage in MuPDF: keep a marker.
    html = html:gsub("<svg[^>]*>.-</svg>", '<span class="omitted">[公式]</span>')

    -- 2. Images: resolve the lazy-load attribute, keep src only.
    local img_width = getRenderImgWidth()
    html = html:gsub("<img([^>]*)>", function(attrs)
        attrs = attrs or ""
        -- data-original / data-actualsrc / data-src hold the real picture; the
        -- plain src is often a low-resolution placeholder, which is the second
        -- reason a picture shows up tiny.
        local src = attrs:match('data%-original%s*=%s*"([^"]*)"')
            or attrs:match("data%-original%s*=%s*'([^']*)'")
            or attrs:match('data%-actualsrc%s*=%s*"([^"]*)"')
            or attrs:match("data%-actualsrc%s*=%s*'([^']*)'")
            or attrs:match('data%-src%s*=%s*"([^"]*)"')
            or attrs:match("data%-src%s*=%s*'([^']*)'")
            or attrs:match('src%s*=%s*"([^"]*)"')
            or attrs:match("src%s*=%s*'([^']*)'")
        if not src or src == "" then
            return '<span class="omitted">[图片]</span>'
        end
        if src:sub(1, 2) == "//" then src = "https:" .. src end
        src = src:gsub("&", "&amp;"):gsub('"', "&quot;")

        -- Emoji / stickers are inline glyphs: scaling them to full width would
        -- be absurd, so they stay at their intrinsic size.
        local cls = attrs:match('class%s*=%s*"([^"]*)"') or attrs:match("class%s*=%s*'([^']*)'")
        local declared = attrs:match('data%-rawwidth%s*=%s*"(%d+)"')
            or attrs:match('width%s*=%s*"(%d+)"')
        local tiny = false
        if cls and cls:lower():find("emo") then
            tiny = true
        elseif declared and tonumber(declared) and tonumber(declared) <= 160 then
            tiny = true
        end
        if tiny then
            return '<img src="' .. src .. '" class="tiny-img"/>'
        end
        if img_width and img_width > 0 then
            return '<img src="' .. src .. '" class="full-img" width="' .. tostring(img_width) .. '"/>'
        end
        return '<img src="' .. src .. '"/>'
    end)

    -- 3. Every other tag keeps its name plus its class (the stylesheet needs
    -- .answer / .voteup / .nav-btn), and loses every other attribute.
    html = html:gsub("<(%a+)([^>]*)>", function(tag, attrs)
        attrs = attrs or ""
        if tag == "img" then
            local src = attrs:match('src%s*=%s*"([^"]*)"')
            if not src then return '<span class="omitted">[图片]</span>' end
            local wpx = attrs:match('width%s*=%s*"(%d+)"')
            local icls = attrs:match('class%s*=%s*"([^"]*)"')
            local out = '<img src="' .. src .. '"'
            if wpx then out = out .. ' width="' .. wpx .. '"' end
            if icls then out = out .. ' class="' .. icls .. '"' end
            return out .. '/>'
        end
        if tag == "a" then
            -- v140: anchors must keep their target, otherwise the in-page
            -- "下一个" / "上一批" links are stripped and cannot be tapped.
            local href = attrs:match('href%s*=%s*"([^"]*)"') or attrs:match("href%s*=%s*'([^']*)'")
            if href and href ~= "" then
                href = href:gsub("&", "&amp;"):gsub('"', "&quot;")
                return '<a href="' .. href .. '">'
            end
            return "<a>"
        end
        local class = attrs:match('class%s*=%s*"([^"]*)"') or attrs:match("class%s*=%s*'([^']*)'")
        if class and class ~= "" then
            class = class:gsub("&", "&amp;")
            class = class:gsub('"', "")
            class = class:gsub("'", "")
            return "<" .. tag .. ' class="' .. class .. '">'
        end
        return "<" .. tag .. ">"
    end)

    -- 4. XHTML-legal empty tags.
    html = html:gsub("<br>", "<br/>")
    html = html:gsub("<hr>", "<hr/>")

    -- 5. Drop empty containers: each one still costs a layout box.
    for _ = 1, 3 do
        html = html:gsub("<p%s*></p>", "")
        html = html:gsub("<div%s*></div>", "")
        html = html:gsub("<span%s*></span>", "")
        html = html:gsub("<blockquote%s*></blockquote>", "")
        html = html:gsub("<li%s*></li>", "")
    end

    -- 6. Collapse whitespace runs left over from the source indentation.
    html = html:gsub("[\r\n\t]+", " ")
    html = html:gsub("  +", " ")

    -- 7. Final entity pass (also fixes ampersands inside src URLs).
    html = normalizeEntities(html)

    return html
end

-- Extract js-initialData JSON from a Zhihu HTML page
local function extractInitialData(html)
    if not html or html == "" then return nil end
    local json_str = html:match('id="js%-initialData"[^>]*>(.-)</script>')
    if not json_str then
        json_str = html:match('<script[^>]*js%-initialData[^>]*>(.-)</script>')
    end
    if not json_str then return nil end
    json_str = json_str:gsub("&quot;", '"')
    json_str = json_str:gsub("&amp;", "&")
    json_str = json_str:gsub("&lt;", "<")
    json_str = json_str:gsub("&gt;", ">")
    json_str = json_str:gsub("&#39;", "'")
    return decodeJSON(json_str)
end

-- =========================================================================
-- CookieJar
-- =========================================================================

local CookieJar = {}
CookieJar.__index = CookieJar

function CookieJar:new() return setmetatable({cookies = {}}, self) end

function CookieJar:parseSetCookie(header_value)
    if not header_value then return end
    if type(header_value) == "table" then
        for _, v in ipairs(header_value) do self:parseSetCookie(v) end
        return
    end
    -- Headers may contain multiple cookies separated by commas.
    -- Expires values also contain commas, so we only split at cookie boundaries.
    local cookies = {}
    local current = {}
    local in_quotes = false
    local i = 1
    while i <= #header_value do
        local c = header_value:sub(i, i)
        if c == '"' then
            in_quotes = not in_quotes
            table.insert(current, c)
        elseif c == ',' and not in_quotes then
            -- Peek ahead: if next non-space char starts a new name, split here
            local j = i + 1
            while j <= #header_value and header_value:sub(j, j):match("%s") do
                j = j + 1
            end
            if j <= #header_value and header_value:sub(j, j):match("[%w_]") then
                if #current > 0 then
                    table.insert(cookies, table.concat(current))
                end
                current = {}
                i = j - 1 -- will be incremented
            else
                table.insert(current, c)
            end
        else
            table.insert(current, c)
        end
        i = i + 1
    end
    if #current > 0 then
        table.insert(cookies, table.concat(current))
    end

    for _, cookie_str in ipairs(cookies) do
        local segments = {}
        for seg in cookie_str:gmatch("([^;]+)") do
            table.insert(segments, (seg:gsub("^%s+", "")))
        end
        if #segments > 0 then
            local first = segments[1]
            local eq_pos = first:find("=", 1, true)
            if eq_pos then
                local name = first:sub(1, eq_pos - 1):gsub("^%s+", ""):gsub("%s+$", "")
                local value = first:sub(eq_pos + 1):gsub("^%s+", ""):gsub("%s+$", "")
                local lname = name:lower()
                if lname ~= "path" and lname ~= "domain" and lname ~= "expires"
                   and lname ~= "max-age" and lname ~= "secure" and lname ~= "httponly"
                   and lname ~= "samesite" and lname ~= "version" then
                    self.cookies[name] = value
                end
            end
        end
    end
end

function CookieJar:getCookieString()
    local parts = {}
    for name, value in pairs(self.cookies) do
        table.insert(parts, name .. "=" .. value)
    end
    return table.concat(parts, "; ")
end

function CookieJar:get(name) return self.cookies[name] end
function CookieJar:set(name, value) self.cookies[name] = value end
function CookieJar:isLoggedIn()
    return self.cookies["z_c0"] ~= nil and self.cookies["z_c0"] ~= ""
end
function CookieJar:clear() self.cookies = {} end

function CookieJar:save(filepath)
    local f = io.open(filepath, "w")
    if not f then return false end
    f:write("return {\n")
    for name, value in pairs(self.cookies) do
        f:write(string.format("  [%q] = %q,\n", name, value))
    end
    f:write("}\n")
    f:close()
    return true
end

function CookieJar:load(filepath)
    local f = io.open(filepath, "r")
    if not f then return false end
    f:close()
    local ok, cookies = pcall(dofile, filepath)
    if ok and type(cookies) == "table" then
        self.cookies = cookies
        return true
    end
    return false
end

-- =========================================================================
-- ZhihuClient
-- =========================================================================

local ZhihuClient = {}
ZhihuClient.__index = ZhihuClient

function ZhihuClient:new()
    local o = setmetatable({}, self)
    o.cookie_jar = CookieJar:new()
    o.cookie_file = nil
    o.last_error = ""
    -- v151: main.lua sets this from the "answerer avatar" setting before it
    -- asks for a page; the rendered HTML then carries <img class="avatar">.
    o.show_avatar = false
    return o
end

function ZhihuClient:init(settings_dir)
    self.cookie_file = settings_dir .. "/zhihu_cookies.lua"
    self.cookie_jar:load(self.cookie_file)
end

function ZhihuClient:reloadCookies()
    return self.cookie_jar:load(self.cookie_file)
end

function ZhihuClient:isLoggedIn() return self.cookie_jar:isLoggedIn() end

function ZhihuClient:saveCookies()
    if self.cookie_file then return self.cookie_jar:save(self.cookie_file) end
    return false
end

function ZhihuClient:logout()
    self.cookie_jar:clear()
    if self.cookie_file then
        local f = io.open(self.cookie_file, "w")
        if f then f:write("return {}\n") f:close() end
    end
end

function ZhihuClient:getLastError() return self.last_error or "" end

-- Get logged-in user name from cookies or API
function ZhihuClient:getUserName()
    if not self:isLoggedIn() then return nil end
    local body, code = self:_request("https://www.zhihu.com/api/v4/me", "GET", "https://www.zhihu.com/")
    if body and code == 200 then
        local data = decodeJSON(body)
        if data and data.name then return data.name end
    end
    return nil
end

-- =========================================================================
-- HTTP
-- =========================================================================

function ZhihuClient:_buildHeaders(method, referer, is_image)
    local headers = {
        ["User-Agent"]      = USER_AGENT,
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
        ["Referer"]         = referer or "https://www.zhihu.com",
    }
    if is_image then
        headers["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
    else
        headers["Accept"] = "text/html,application/json,*/*;q=0.8"
    end
    local cookie_str = self.cookie_jar:getCookieString()
    if cookie_str ~= "" then headers["Cookie"] = cookie_str end
    if method == "POST" then
        local xsrf = self.cookie_jar:get("_xsrf")
        if xsrf then
            xsrf = urlDecode(xsrf)
            xsrf = xsrf:gsub('^"', ""):gsub('"$', "")
            headers["x-xsrftoken"] = xsrf
        end
    end
    return headers
end

function ZhihuClient:_request(url, method, referer, is_image)
    method = method or "GET"
    local sink = {}
    local headers = self:_buildHeaders(method, referer, is_image)
    local request_params = {
        url = url, method = method, headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if method == "POST" then
        request_params.source = ltn12.source.string("")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Content-Length"] = "0"
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, r1, r_code, r_headers = pcall(https.request, request_params)
    socketutil:reset_timeout()
    if not ok then
        self.last_error = tostring(r1 or "request error")
        return nil, 0, nil
    end
    if not r1 then
        self.last_error = tostring(r_code or "connection failed")
        return nil, 0, nil
    end
    local status_code = tonumber(r_code) or 0
    local response_body = table.concat(sink)
    if r_headers and r_headers["set-cookie"] then
        self.cookie_jar:parseSetCookie(r_headers["set-cookie"])
    end
    return response_body, status_code, r_headers
end

function ZhihuClient:downloadFile(url, filepath, referer)
    local body, code = self:_request(url, "GET", referer, true)
    if not body then return nil, code end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    local f = io.open(filepath, "wb")
    if not f then return nil, "Cannot open file" end
    f:write(body) f:close()
    return true
end

-- Alias for image download (used by showImage)
function ZhihuClient:_downloadImage(url, filepath)
    return self:downloadFile(url, filepath, "https://www.zhihu.com/")
end

-- =========================================================================
-- Initial Cookies
-- =========================================================================

function ZhihuClient:getInitialCookies()
    local _, code1 = self:_request("https://www.zhihu.com/signin", "GET", "https://www.zhihu.com")
    if not code1 or code1 == 0 then return false, "Cannot connect to zhihu.com" end
    self:_request("https://www.zhihu.com/udid", "POST", "https://www.zhihu.com/signin")
    self:_request("https://www.zhihu.com/api/v3/oauth/captcha?lang=cn", "GET", "https://www.zhihu.com/signin")
    if not self.cookie_jar:get("_xsrf") then
        return false, "Failed to get _xsrf cookie"
    end
    return true
end

-- =========================================================================
-- QR Code Login
-- =========================================================================

function ZhihuClient:getQrCodeToken()
    if not self.cookie_jar:get("_xsrf") then
        local ok, err = self:getInitialCookies()
        if not ok then return nil, err end
    end
    local body, code = self:_request(
        "https://www.zhihu.com/api/v3/account/api/login/qrcode", "POST",
        "https://www.zhihu.com/signin")
    if not body then return nil, code end
    if code ~= 200 and code ~= 201 then return nil, "HTTP " .. tostring(code) end
    local data = decodeJSON(body)
    if not data then return nil, "JSON parse failed" end
    if not data.token then return nil, "No token in response" end
    -- Store token and scan link for QR generation
    self._qr_token = data.token
    if data.link then
        self.scan_link = data.link
    end
    return data.token
end

function ZhihuClient:getQrCodeImageUrl(scan_url)
    -- Use third-party QR API since Zhihu's image endpoint blocks non-browser clients
    local login_url = scan_url
        or ("https://www.zhihu.com/account/scan/login/" .. (self._qr_token or ""))
    -- URL-encode for the QR API
    local encoded = login_url:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+")
    return "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=" .. encoded
end

function ZhihuClient:downloadQrImage(token, filepath)
    -- Try Zhihu's own QR image endpoint first
    local zhihu_url = "https://www.zhihu.com/api/v3/account/api/login/qrcode/" .. token .. "/image"
    local ok = self:downloadFile(zhihu_url, filepath, "https://www.zhihu.com/signin")
    if ok then return true end

    -- Fallback: third-party QR code generation API
    local scan_url = self:getScanUrl(token)
    local qr_api_url = self:getQrCodeImageUrl(scan_url)
    return self:downloadFile(qr_api_url, filepath, "https://www.zhihu.com/signin")
end

function ZhihuClient:getScanUrl(token)
    return self.scan_link
        or ("https://www.zhihu.com/account/scan/login/" .. (token or ""))
end

function ZhihuClient:_applyCookieString(str)
    -- Apply a raw "name=value; name2=value2" cookie string (e.g. from JSON "cookie" field)
    if not str or str == "" then return end
    for seg in str:gmatch("([^;]+)") do
        local s = seg:gsub("^%s+", ""):gsub("%s+$", "")
        local eq = s:find("=", 1, true)
        if eq then
            local name = s:sub(1, eq - 1)
            local value = s:sub(eq + 1)
            local lname = name:lower()
            if lname ~= "path" and lname ~= "domain" and lname ~= "expires"
               and lname ~= "max-age" and lname ~= "secure" and lname ~= "httponly"
               and lname ~= "samesite" and lname ~= "version" then
                self.cookie_jar.cookies[name] = value
            end
        end
    end
end

function ZhihuClient:checkScanStatus(token)
    local url = "https://www.zhihu.com/api/v3/account/api/login/qrcode/" .. token .. "/scan_info"
    local body, code, headers = self:_request(url, "GET", "https://www.zhihu.com/signin")

    -- z_c0 cookie is the definitive login indicator (may arrive via set-cookie header)
    if self.cookie_jar:get("z_c0") then return "confirmed" end

    if body then
        local ok, data = pcall(decodeJSON, body)
        if ok and data then
            -- v128: Zhihu risk control ("unhuman"). The API answers HTTP 403 with
            -- error code 40352 and a redirect to a human-verification page when the
            -- network is flagged (common on mobile-data / carrier NAT IPs, e.g.
            -- Android phones). Such a response carries no "status" field, so the old
            -- code treated it as "waiting" and polled forever ("no reaction" after
            -- scanning). Surface it as "blocked" plus the verification URL instead.
            if data.error and (data.error.need_login or data.error.code == 40352) then
                self.last_error = data.error.message or "risk control blocked"
                local verify_url = data.error.redirect
                if verify_url then verify_url = tostring(verify_url) end
                return "blocked", verify_url
            end
            if data.status ~= nil then
                local status = data.status
                -- On confirm, Zhihu often sends the auth cookies inside the JSON "cookie" field.
                if (status == 2 or status == "confirmed") and data.cookie then
                    self:_applyCookieString(tostring(data.cookie))
                end
                if self.cookie_jar:get("z_c0") then return "confirmed" end
                if status == 0 then return "waiting" end
                if status == 1 then return "scanned" end
                if status == 2 then return "confirmed" end
                if status == 3 then return "expired" end
            end
        end
    end

    if code == 404 or code == 410 then return "expired" end
    return "waiting"
end

-- v128: Drop all cookies (including the risk-flagged d_c0 device id) and fetch
-- a fresh set of initial cookies. Used by the risk-control dialog to retry
-- login from a clean device identity.
function ZhihuClient:resetSession()
    self.cookie_jar:clear()
    return self:getInitialCookies()
end

-- =========================================================================
-- Recommend Feed
-- =========================================================================

function ZhihuClient:getRecommendFeed(start_url, max_pages, max_items)
    max_pages = max_pages or 3
    -- v127: the Recommended Feed list showed a fixed 12 items per batch.
    -- v159: the batch size comes from the caller (multiple of 6, 12 if unset).
    max_items = math.floor(tonumber(max_items) or 12)
    if max_items < 1 then max_items = 12 end
    if not self:isLoggedIn() then return nil, "Not logged in" end

    local base_url = "https://www.zhihu.com/api/v3/feed/topstory/recommend?limit=20&desktop=true"
    local url = start_url or base_url

    local all_items = {}
    local seen = {}
    local next_url = nil

    for page = 1, max_pages do
        local body, code = self:_request(url, "GET", "https://www.zhihu.com/")
        if not body or code ~= 200 then
            self.last_error = "API HTTP " .. tostring(code or "failed")
            break
        end

        local data = decodeJSON(body)
        if not data or not data.data then break end

        for _, item in ipairs(data.data) do
            local target = item.target or {}
            local ttype = (target.type or ""):lower()

            -- Resolve id + type for all openable card kinds
            local question_id, item_type
            if ttype:match("answer") then
                item_type = "answer"
                if target.question and target.question.id then
                    question_id = target.question.id
                elseif target.url then
                    question_id = target.url:match("question/(%d+)")
                end
            elseif ttype:match("article") or ttype:match("column") then
                item_type = "article"
                question_id = target.id or (target.url and target.url:match("p/(%d+)"))
            elseif ttype:match("question") then
                item_type = "answer"
                question_id = target.id
            else
                -- Unknown card: best-effort from URL
                question_id = target.url and (target.url:match("question/(%d+)")
                    or target.url:match("p/(%d+)"))
            end

            local title = (target.question and target.question.title) or target.title or ""

            -- Drop cards we cannot open (video / promotion / live / roundtable / idea)
            local skip = ttype == ""
                or ttype:match("video") or ttype:match("promotion")
                or ttype:match("roundtable") or ttype:match("live")
                or ttype:match("idea") or ttype:match("zvideo")

            if not skip and title ~= "" and question_id and question_id ~= "" then
                local key = item_type .. ":" .. question_id
                if not seen[key] then
                    seen[key] = true
                    local author = (target.author and target.author.name) or ""
                    table.insert(all_items, {
                        index       = #all_items + 1,
                        title       = title,
                        item_type   = item_type,
                        question_id = tostring(question_id),
                        author      = author,
                        content     = "",
                        voteup      = target.voteup_count or 0,
                        images      = {},
                    })
                end
            end
        end

        -- Follow cursor pagination (zhihu returns paging.next + paging.is_end).
        -- The cursor is always advanced BEFORE the item-count check, so
        -- "Load More" continues from the true next page even when we stop
        -- early after reaching the batch cap.
        if data.paging and data.paging.next and not data.paging.is_end then
            next_url = data.paging.next
            url = data.paging.next
        else
            next_url = nil
            break
        end

        -- v127: stop accumulating once the batch is full
        if #all_items >= max_items then break end
    end

    -- v127: trim the batch to exactly the list size
    for i = #all_items, max_items + 1, -1 do
        all_items[i] = nil
    end

    if #all_items == 0 then return nil, "No items" end
    return all_items, next_url
end

-- =========================================================================
-- Search
-- =========================================================================

function ZhihuClient:search(keyword)
    if not keyword or keyword == "" then return nil, "Empty keyword" end
    if not self.cookie_jar:get("d_c0") then
        self:getInitialCookies()
    end

    -- URL encode the keyword
    local encoded = keyword:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+")

    local url = "https://www.zhihu.com/api/v4/search_v3?t=general&q=" .. encoded
        .. "&correction=1&offset=0&limit=20"

    local body, code = self:_request(url, "GET", "https://www.zhihu.com/search")
    if not body or code ~= 200 then
        self.last_error = "Search API HTTP " .. tostring(code or "failed")
        return nil
    end

    local data = decodeJSON(body)
    if not data or not data.data then return nil, "No search results" end

    local items = {}
    for _, item in ipairs(data.data) do
        local obj = item.object or {}
        local question_id = nil
        local item_type = "answer"
        local title = ""

        -- Search results have different structure
        if obj.type then
            local otype = obj.type:lower()
            if otype:match("question") then
                question_id = obj.id
                title = obj.title or ""
            elseif otype:match("answer") then
                if obj.question then
                    question_id = obj.question.id
                    title = obj.question.title or ""
                end
            elseif otype:match("article") then
                question_id = obj.id
                item_type = "article"
                title = obj.title or ""
            end
        end

        if not title or title == "" then
            title = obj.title or obj.name or "No Title"
        end

        if question_id and title ~= "" then
            table.insert(items, {
                index       = #items + 1,
                title       = title,
                question_id = tostring(question_id),
                item_type   = item_type,
                excerpt     = obj.excerpt or "",
            })
        end
    end

    if #items == 0 then return nil, "No matching results" end
    return items
end

-- =========================================================================
-- Get Answers for a Question
--   Strategy 1: Answers API with simplified include params (primary)
--   Strategy 2: Question page HTML with correct Referer (fallback)
-- =========================================================================

function ZhihuClient:getAnswers(question_id, title, item_type, show_images)
    if not question_id or question_id == "" then
        return nil, "No question ID"
    end
    question_id = tostring(question_id):match("(%d+)") or question_id
    item_type = item_type or "answer"

    if not self.cookie_jar:get("d_c0") then
        self:getInitialCookies()
    end

    if item_type == "article" then
        return self:_getArticleContent(question_id, title, show_images)
    end

    -- Strategy 1: Simplified API (remove long include param that triggers 403)
    local text, images = self:_getAnswersViaApi(question_id, title, show_images)
    if text then return text, images end

    -- Strategy 2: HTML page with correct Referer
    logger.info("[Zhihu] API failed, trying HTML page for:", question_id)
    return self:_getAnswersViaPage(question_id, title, show_images)
end

function ZhihuClient:_getAnswersViaApi(question_id, title, show_images)
    -- v35: add include=content to get answer body
    local url = "https://www.zhihu.com/api/v4/questions/" .. question_id
        .. "/answers?limit=5&offset=0&include=data[*].content,voteup_count,created_time,author"

    local qurl = "https://www.zhihu.com/question/" .. question_id
    local body, code = self:_request(url, "GET", qurl)

    if not body or code ~= 200 then
        self.last_error = "Answers API HTTP " .. tostring(code or "failed")
        return nil
    end

    local data = decodeJSON(body)
    if not data or not data.data or #data.data == 0 then
        self.last_error = "No answers in API response"
        return nil
    end

    return self:_formatAnswers(data.data, title, show_images)
end

function ZhihuClient:_getAnswersViaPage(question_id, title, show_images)
    local url = "https://www.zhihu.com/question/" .. question_id
    -- v18 fix: use question URL as referer (not generic zhihu.com)
    local body, code = self:_request(url, "GET", url)

    if not body or code ~= 200 then
        self.last_error = "Page HTTP " .. tostring(code or "failed")
        return nil
    end

    -- Check if redirected to article
    if body:match("zhuanlan") and body:match("article") then
        return self:_getArticleContent(question_id, title, show_images)
    end

    local data = extractInitialData(body)
    if not data then
        self.last_error = "Cannot parse page"
        return nil
    end

    -- Navigate to entities
    local entities = data
    if entities and entities.initialState then entities = entities.initialState end
    if entities and entities.entities then entities = entities.entities end
    if not entities then
        self.last_error = "No entities"
        return nil
    end

    -- Get title
    if (not title or title == "") and entities.questions then
        for _, q in pairs(entities.questions) do
            if q.title then title = q.title break end
        end
    end

    -- Get answers
    local answers = entities.answers
    local answer_list = {}

    if answers and type(answers) == "table" then
        for _, ans in pairs(answers) do
            local author_name = "Anonymous"
            -- v151: keep the avatar next to the name when the payload has one
            local author_avatar = nil
            if ans.author then
                if type(ans.author) == "table" then
                    author_name = ans.author.name or "Anonymous"
                    author_avatar = ans.author.avatarUrl or ans.author.avatar_url
                        or ans.author.avatarUrlTemplate or ans.author.avatar_url_template
                elseif type(ans.author) == "string" and entities.users then
                    local uid = ans.author:match("(%d+)")
                    if uid and entities.users[uid] then
                        author_name = entities.users[uid].name or "Anonymous"
                        author_avatar = entities.users[uid].avatarUrl
                            or entities.users[uid].avatar_url
                    end
                end
            end
            table.insert(answer_list, {
                author_name  = author_name,
                author_avatar = author_avatar,
                voteup_count = ans.voteupCount or ans.voteup_count or 0,
                content      = ans.content or "",
            })
        end
    end

    -- Sort by voteup
    table.sort(answer_list, function(a, b)
        return (a.voteup_count or 0) > (b.voteup_count or 0)
    end)

    if #answer_list > DEFAULT_PAGE_SIZE then
        for i = #answer_list, DEFAULT_PAGE_SIZE + 1, -1 do answer_list[i] = nil end
    end

    if #answer_list == 0 then
        -- No answers - try question excerpt
        local qdata = nil
        if entities.questions then
            for _, q in pairs(entities.questions) do qdata = q break end
        end
        if qdata then
            local excerpt = qdata.excerpt or qdata.detail or ""
            local formatted = {{
                author = { name = "知乎" },
                voteup_count = 0,
                content = excerpt,
            }}
            return self:_formatAnswers(formatted, title, show_images)
        end
        self.last_error = "No answers or question data"
        return nil
    end

    local formatted = {}
    for _, ans in ipairs(answer_list) do
        table.insert(formatted, {
            author = { name = ans.author_name, avatar_url = ans.author_avatar },
            voteup_count = ans.voteup_count,
            content = ans.content,
        })
    end

    return self:_formatAnswers(formatted, title, show_images)
end

function ZhihuClient:_getArticleContent(article_id, title, show_images)
    local url = "https://zhuanlan.zhihu.com/p/" .. article_id
    local body, code = self:_request(url, "GET", "https://www.zhihu.com/")

    if not body or code ~= 200 then
        self.last_error = "Article HTTP " .. tostring(code or "failed")
        return nil
    end

    local data = extractInitialData(body)
    if not data then
        self.last_error = "Cannot parse article"
        return nil
    end

    local entities = data
    if entities and entities.initialState then entities = entities.initialState end
    if entities and entities.entities then entities = entities.entities end
    if not entities then
        self.last_error = "No entities"
        return nil
    end

    local article = nil
    if entities.articles then article = entities.articles[article_id] end
    if not article and entities.posts then article = entities.posts[article_id] end

    if not article then
        self.last_error = "Article not found"
        return nil
    end

    if not title or title == "" then
        title = article.title or "Article"
    end

    local content = article.content or article.excerpt or "(content not available)"
    local author = "Unknown"
    if article.author then
        if type(article.author) == "table" then
            author = article.author.name or "Unknown"
        elseif entities.users then
            local uid = tostring(article.author):match("(%d+)")
            if uid and entities.users[uid] then
                author = entities.users[uid].name or "Unknown"
            end
        end
    end
    local voteup = article.voteup_count or article.voteupCount or 0

    local formatted = {{
        author = { name = author },
        voteup_count = voteup,
        content = content,
    }}

    return self:_formatAnswers(formatted, title, show_images)
end

function ZhihuClient:_formatAnswers(answers, title, show_images)
    if not answers or #answers == 0 then return nil, {} end

    local parts = {}
    local all_images = {}
    if title then
        table.insert(parts, title)
        table.insert(parts, SEPARATOR)
        table.insert(parts, "")
    end

    for i, answer in ipairs(answers) do
        local author = (answer.author and answer.author.name) or "Anonymous"
        local voteup = answer.voteup_count or answer.voteupCount or 0
        local content, images = htmlToText(answer.content or "", show_images)
        if images and #images > 0 then
            for _, img in ipairs(images) do
                table.insert(all_images, img)
            end
        end
        if content == "" then content = "(content not available)" end

        local time_str = formatTime(answer.created_time or answer.createdTime)
        if time_str ~= "" then
            time_str = "  ·  " .. time_str
        end

        table.insert(parts, string.format("[%d] %s   %s%s", i, author, voteup .. " votes", time_str))
        table.insert(parts, "")
        table.insert(parts, content)
        table.insert(parts, "")
        table.insert(parts, SEPARATOR)
        table.insert(parts, "")
    end

    return table.concat(parts, "\n"), all_images
end

function ZhihuClient:getRawQuestionHtml(question_id)
    local url = "https://www.zhihu.com/question/" .. question_id
    local body, code = self:_request(url, "GET", url)
    if not body or code ~= 200 then
        return nil, "HTTP " .. tostring(code)
    end
    return body
end

function ZhihuClient:getRawArticleHtml(article_id)
    local url = "https://zhuanlan.zhihu.com/p/" .. article_id
    local body, code = self:_request(url, "GET", "https://www.zhihu.com/")
    if not body or code ~= 200 then
        return nil, "HTTP " .. tostring(code)
    end
    return body
end

-- =========================================================================
-- EPUB Content (HTML format for ebook generation)
-- =========================================================================

-- v151: the answerer's avatar URL, whichever shape the payload uses. Zhihu
-- ships a template ("..._{size}.jpg") for its members and plain URLs in the
-- page payload; both are handled here. Returns nil when none is present.
local function answerAvatarUrl(answer)
    if type(answer) ~= "table" then return nil end
    local u = answer.avatar_url or answer.avatarUrl
    if type(u) ~= "string" or u == "" then
        local a = answer.author
        if type(a) == "table" then
            u = a.avatar_url_template or a.avatarUrlTemplate
                or a.avatar_url or a.avatarUrl
            if type(u) ~= "string" or u == "" then
                local m = a.member
                if type(m) == "table" then
                    u = m.avatar_url_template or m.avatarUrlTemplate
                        or m.avatar_url or m.avatarUrl
                end
            end
        end
    end
    if type(u) ~= "string" or u == "" then return nil end
    -- "m" is ~200px: enough for an e-ink screen after crengine scales it down,
    -- small enough to stay a few KB.
    if u:find("{size}", 1, true) then
        u = u:gsub("{size}", "m")
    else
        -- plain URLs often already carry a size suffix (_xl / _l / _r / _b /
        -- _hd / _is); ask for the small one instead of a full-resolution file
        u = u:gsub("_(" .. "xl|l|r|hd|b|is" .. ")(%.[%a]+)$", "_m%2")
    end
    return u
end

function ZhihuClient:_formatAnswersHtml(answers, title, opts)
    if not answers or #answers == 0 then return nil end
    opts = opts or {}
    -- v151: callers that do not care about the switch just omit it
    if opts.show_avatar == nil then opts.show_avatar = self.show_avatar and true or false end
    local start_no = (tonumber(opts.start_no) or 1) - 1

    local parts = {}
    if title and opts.show_title ~= false then
        table.insert(parts, '<h1 class="title">' .. escapeXml(title) .. '</h1>')
    end

    for i, answer in ipairs(answers) do
        local author = (answer.author and answer.author.name) or "Anonymous"
        local voteup = answer.voteup_count or answer.voteupCount or 0
        local content = answer.content or ""

        content = cleanHtmlForRender(content)
        -- v140: a single answer can be hundreds of KB; layout cost grows with
        -- it and paging becomes unusable, so keep the first slice.
        if #content > MAX_ANSWER_HTML_BYTES then
            local cut = content:sub(1, MAX_ANSWER_HTML_BYTES)
            -- never cut inside a tag: drop the trailing partial tag
            local lt = cut:match(".*()<")
            if lt and lt > (#cut - 200) then
                cut = cut:sub(1, lt - 1)
            end
            content = cut .. '<p class="omitted">（回答内容过长，已截断显示）</p>'
        end
        if content == "" then content = '<p>(content not available)</p>' end

        local time_str = formatTime(answer.created_time or answer.createdTime)
        local meta_line = tostring(voteup) .. " votes"
        if time_str ~= "" then
            meta_line = meta_line .. "  ·  " .. time_str
        end
        -- v140: number answers so the reader knows where a page starts.
        local heading = string.format("#%d  %s", start_no + i, author)

        local avatar = nil
        if opts.show_avatar then avatar = answerAvatarUrl(answer) end

        if avatar then
            -- v151: the avatar rides inside the heading, so it always sits
            -- next to the name it belongs to and never takes a line of its own.
            table.insert(parts, string.format(
                '<div class="answer"><h2 class="author"><img class="avatar" src="%s"/>%s</h2><p class="voteup">%s</p>%s</div>',
                escapeXml(avatar), escapeXml(heading), meta_line, content
            ))
        else
            table.insert(parts, string.format(
                '<div class="answer"><h2 class="author">%s</h2><p class="voteup">%s</p>%s</div>',
                escapeXml(heading), meta_line, content
            ))
        end
    end

    return table.concat(parts, '\n')
end

-- -------------------------------------------------------------------------
-- v140: paged answer rendering + on-disk page cache
-- -------------------------------------------------------------------------

function ZhihuClient:setCacheDir(dir)
    self.cache_dir = dir
end

function ZhihuClient:setCacheTTL(seconds)
    self.cache_ttl = tonumber(seconds) or DEFAULT_CACHE_TTL
end

local function pageCacheName(question_id, offset, limit)
    return string.format("%s_p%d_n%d.html", tostring(question_id), offset, limit)
end

-- v151: the page HTML depends on the avatar setting, so a turning on/off
-- switch must not be served a page rendered with the other value.
local function pageCacheFile(question_id, offset, limit, show_avatar)
    local name = pageCacheName(question_id, offset, limit)
    if show_avatar then name = "av_" .. name end
    return name
end

-- First line of a cache file is "timestamp|count|has_more", the rest is HTML.
function ZhihuClient:readCachedPage(question_id, offset, limit)
    if not self.cache_dir or not question_id then return nil end
    local path = self.cache_dir .. "/" .. pageCacheFile(question_id, offset, limit, self.show_avatar)
    local f = io.open(path, "rb")
    if not f then return nil end
    local header = f:read("*l")
    if not header then
        f:close()
        return nil
    end
    local ts, count, has_more = header:match("^(%d+)|(%d+)|(%d+)$")
    if not ts then
        f:close()
        pcall(os.remove, path)
        return nil
    end
    local ttl = self.cache_ttl or DEFAULT_CACHE_TTL
    if ttl > 0 and (os.time() - tonumber(ts)) > ttl then
        f:close()
        pcall(os.remove, path)
        return nil
    end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then return nil end
    return body, {
        offset = offset,
        limit = limit,
        count = tonumber(count) or 0,
        has_more = (has_more == "1"),
        from_cache = true,
    }
end

function ZhihuClient:writeCachedPage(question_id, offset, limit, body, info)
    if not self.cache_dir or not question_id or not body or body == "" then
        return false
    end
    info = info or {}
    local path = self.cache_dir .. "/" .. pageCacheFile(question_id, offset, limit, self.show_avatar)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(string.format("%d|%d|%d\n", os.time(), info.count or 0, info.has_more and 1 or 0))
    f:write(body)
    f:close()
    return true
end

function ZhihuClient:clearPageCache()
    if not self.cache_dir then return 0 end
    local removed = 0
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and lfs.dir then
        local ok_dir = pcall(function()
            for entry in lfs.dir(self.cache_dir) do
                if entry:match("%.html$") then
                    if os.remove(self.cache_dir .. "/" .. entry) then
                        removed = removed + 1
                    end
                end
            end
        end)
        if ok_dir then return removed end
    end
    os.execute("rm -f '" .. self.cache_dir .. "'/*.html 2>/dev/null")
    return removed
end

-- Answers API with explicit offset/limit. Returns html, info.
function ZhihuClient:_getAnswersHtmlApi(question_id, title, offset, limit)
    local url = "https://www.zhihu.com/api/v4/questions/" .. question_id
        .. string.format("/answers?limit=%d&offset=%d", limit, offset)
        .. "&include=data[*].content,voteup_count,created_time,author"
    local qurl = "https://www.zhihu.com/question/" .. question_id
    local body, code = self:_request(url, "GET", qurl)

    if not body or code ~= 200 then
        self.last_error = "Answers API HTTP " .. tostring(code or "failed")
        return nil
    end

    local data = decodeJSON(body)
    if not data or not data.data then
        self.last_error = "No answers in API response"
        return nil
    end
    if #data.data == 0 then
        self.last_error = "No more answers"
        return nil
    end

    -- Trust the paging block when present; otherwise a short page means the end.
    local has_more
    if data.paging and data.paging.is_end ~= nil then
        has_more = not data.paging.is_end
    else
        has_more = (#data.data >= limit)
    end

    local html = self:_formatAnswersHtml(data.data, title, {
        start_no = offset + 1,
        show_avatar = self.show_avatar and true or false,
    })
    if not html then
        self.last_error = "Cannot format answers"
        return nil
    end
    return html, {
        offset = offset,
        limit = limit,
        count = #data.data,
        has_more = has_more,
        source = "api",
    }
end

-- Render one page of answers (5 by default) as HTML.
-- Returns html, page_info {offset, limit, count, has_more, from_cache}; or nil, error.
function ZhihuClient:getAnswersPage(question_id, title, item_type, offset, limit)
    if not question_id or question_id == "" then
        return nil, "No question ID"
    end
    question_id = tostring(question_id):match("(%d+)") or question_id
    item_type = item_type or "answer"
    offset = tonumber(offset) or 0
    limit = tonumber(limit) or DEFAULT_PAGE_SIZE

    if item_type == "article" then
        local html, err = self:_getArticleHtml(question_id, title)
        if not html then return nil, err end
        return html, { offset = 0, limit = 1, count = 1, has_more = false, source = "article" }
    end

    -- Cache first: re-opening a page (or hopping back to it) is instant.
    local cached_html, cached_info = self:readCachedPage(question_id, offset, limit)
    if cached_html then
        return cached_html, cached_info
    end

    if not self.cookie_jar:get("d_c0") then
        self:getInitialCookies()
    end

    local html, info = self:_getAnswersHtmlApi(question_id, title, offset, limit)
    if not html then
        if offset > 0 then
            -- The HTML fallback cannot paginate, so a later batch simply does
            -- not exist there; report the real reason instead of retrying.
            if self.last_error == "" then self.last_error = "No more answers" end
            return nil, self.last_error
        end
        logger.info("[Zhihu] API failed, trying HTML page for:", question_id)
        html, info = self:_getAnswersHtmlViaPage(question_id, title)
    end
    if not html then
        return nil, self.last_error
    end

    info = info or {}
    info.offset = offset
    info.limit = limit
    self:writeCachedPage(question_id, offset, limit, html, info)
    return html, info
end

-- Kept for callers that only need the first page (EPUB export, old paths).
function ZhihuClient:getAnswersHtml(question_id, title, item_type)
    -- v151: exports stay in the plain layout. An avatar in the exported HTML
    -- would be a live zhihu.com URL, i.e. a remote fetch inside the file that
    -- is supposed to be self-contained (and unreadable once offline).
    local saved = self.show_avatar
    self.show_avatar = false
    local html, info = self:getAnswersPage(question_id, title, item_type, 0, DEFAULT_PAGE_SIZE)
    self.show_avatar = saved
    return html, info
end

function ZhihuClient:_getAnswersHtmlViaPage(question_id, title)
    local url = "https://www.zhihu.com/question/" .. question_id
    local body, code = self:_request(url, "GET", url)

    if not body or code ~= 200 then
        self.last_error = "Page HTTP " .. tostring(code or "failed")
        return nil
    end

    if body:match("zhuanlan") and body:match("article") then
        return self:_getArticleHtml(question_id, title)
    end

    local data = extractInitialData(body)
    if not data then
        self.last_error = "Cannot parse page"
        return nil
    end

    local entities = data
    if entities and entities.initialState then entities = entities.initialState end
    if entities and entities.entities then entities = entities.entities end
    if not entities then
        self.last_error = "No entities"
        return nil
    end

    if (not title or title == "") and entities.questions then
        for _, q in pairs(entities.questions) do
            if q.title then title = q.title break end
        end
    end

    local answers = entities.answers
    local answer_list = {}

    if answers and type(answers) == "table" then
        for _, ans in pairs(answers) do
            local author_name = "Anonymous"
            -- v151: keep the avatar next to the name when the payload has one
            local author_avatar = nil
            if ans.author then
                if type(ans.author) == "table" then
                    author_name = ans.author.name or "Anonymous"
                    author_avatar = ans.author.avatarUrl or ans.author.avatar_url
                        or ans.author.avatarUrlTemplate or ans.author.avatar_url_template
                elseif type(ans.author) == "string" and entities.users then
                    local uid = ans.author:match("(%d+)")
                    if uid and entities.users[uid] then
                        author_name = entities.users[uid].name or "Anonymous"
                        author_avatar = entities.users[uid].avatarUrl
                            or entities.users[uid].avatar_url
                    end
                end
            end
            table.insert(answer_list, {
                author = { name = author_name, avatar_url = author_avatar },
                voteup_count = ans.voteupCount or ans.voteup_count or 0,
                content = ans.content or "",
            })
        end
    end

    table.sort(answer_list, function(a, b)
        return (a.voteup_count or 0) > (b.voteup_count or 0)
    end)

    if #answer_list > DEFAULT_PAGE_SIZE then
        for i = #answer_list, DEFAULT_PAGE_SIZE + 1, -1 do answer_list[i] = nil end
    end

    if #answer_list == 0 then
        local qdata = nil
        if entities.questions then
            for _, q in pairs(entities.questions) do qdata = q break end
        end
        if qdata then
            local excerpt = qdata.excerpt or qdata.detail or ""
            local formatted = {{
                author = { name = "Zhihu" },
                voteup_count = 0,
                content = '<p>' .. escapeXml(excerpt) .. '</p>',
            }}
            return self:_formatAnswersHtml(formatted, title)
        end
        self.last_error = "No answers or question data"
        return nil
    end

    return self:_formatAnswersHtml(answer_list, title)
end

function ZhihuClient:_getArticleHtml(article_id, title)
    local url = "https://zhuanlan.zhihu.com/p/" .. article_id
    local body, code = self:_request(url, "GET", "https://www.zhihu.com/")

    if not body or code ~= 200 then
        self.last_error = "Article HTTP " .. tostring(code or "failed")
        return nil
    end

    local data = extractInitialData(body)
    if not data then
        self.last_error = "Cannot parse article"
        return nil
    end

    local entities = data
    if entities and entities.initialState then entities = entities.initialState end
    if entities and entities.entities then entities = entities.entities end
    if not entities then
        self.last_error = "No entities"
        return nil
    end

    local article = nil
    if entities.articles then article = entities.articles[article_id] end
    if not article and entities.posts then article = entities.posts[article_id] end

    if not article then
        self.last_error = "Article not found"
        return nil
    end

    if not title or title == "" then
        title = article.title or "Article"
    end

    local content = article.content or article.excerpt or ""
    local author = "Unknown"
    if article.author then
        if type(article.author) == "table" then
            author = article.author.name or "Unknown"
        elseif entities.users then
            local uid = tostring(article.author):match("(%d+)")
            if uid and entities.users[uid] then
                author = entities.users[uid].name or "Unknown"
            end
        end
    end
    local voteup = article.voteup_count or article.voteupCount or 0

    local formatted = {{
        author = { name = author },
        voteup_count = voteup,
        content = content,
    }}

    return self:_formatAnswersHtml(formatted, title)
end

return ZhihuClient
