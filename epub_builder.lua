-- Minimal EPUB3 builder for Zhihu articles.
-- Based on zhihudaily.koplugin's epub_builder.lua.
-- Adapts to Zhihu answer format: single article with multiple answers as chapters.

local bit = require("bit")

local EpubBuilder = {}

-- ---------------------------------------------------------------------------
-- Zip writer (STORE only)
-- ---------------------------------------------------------------------------

local crc_table
local function crc32(data)
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local c = i
            for _b = 1, 8 do
                if bit.band(c, 1) == 1 then
                    c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
                else
                    c = bit.rshift(c, 1)
                end
            end
            crc_table[i] = c
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = bit.bxor(bit.rshift(crc, 8),
            crc_table[bit.band(bit.bxor(crc, data:byte(i)), 0xFF)])
    end
    return bit.bxor(crc, 0xFFFFFFFF)
end

local function le16(n)
    return string.char(bit.band(n, 0xFF), bit.band(bit.rshift(n, 8), 0xFF))
end

local function le32(n)
    return string.char(
        bit.band(n, 0xFF),
        bit.band(bit.rshift(n, 8), 0xFF),
        bit.band(bit.rshift(n, 16), 0xFF),
        bit.band(bit.rshift(n, 24), 0xFF))
end

-- Entries: { { name = "OEBPS/...", data = "..." }, ... }.
-- Returns the complete zip archive as a string.
local function make_zip(entries)
    local local_headers, central = {}, {}
    local offset = 0
    for i = 1, #entries do
        local name = entries[i].name
        local data = entries[i].data or ""
        local crc = crc32(data)
        local header = table.concat({
            le32(0x04034b50), le16(20), le16(0), le16(0), le16(0), le16(0),
            le32(crc), le32(#data), le32(#data), le16(#name), le16(0), name,
        })
        local_headers[#local_headers + 1] = header
        local_headers[#local_headers + 1] = data
        central[#central + 1] = table.concat({
            le32(0x02014b50), le16(20), le16(20), le16(0), le16(0), le16(0),
            le16(0), le32(crc), le32(#data), le32(#data), le16(#name),
            le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name,
        })
        offset = offset + #header + #data
    end
    local central_data = table.concat(central)
    local eocd = table.concat({
        le32(0x06054b50), le16(0), le16(0), le16(#entries), le16(#entries),
        le32(#central_data), le32(offset), le16(0),
    })
    return table.concat(local_headers) .. central_data .. eocd
end

-- ---------------------------------------------------------------------------
-- EPUB assembly helpers
-- ---------------------------------------------------------------------------

local function xml_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub('"', "&quot;")
    return value
end

local function write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end
    file:write(data)
    file:close()
    return true
end

local function utc_now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function media_type(path)
    local ext = path:match("%.([%w]+)$")
    if ext == "png" then
        return "image/png"
    elseif ext == "gif" then
        return "image/gif"
    elseif ext == "webp" then
        return "image/webp"
    end
    return "image/jpeg"
end

-- Register a local image as an OEBPS asset (deduped by path). Returns the
-- chapter-relative href ("../images/img-001.jpg") or nil when unreadable.
local function collect_image(state, local_path)
    if not local_path then
        return nil
    end
    if state.by_path[local_path] then
        return state.by_path[local_path]
    end
    local data
    do
        local file = io.open(local_path, "rb")
        if not file then
            return nil
        end
        data = file:read("*a")
        file:close()
    end
    if not data or #data == 0 then
        return nil
    end
    local ext = local_path:match("%.([%w]+)$") or "jpg"
    state.count = state.count + 1
    local href = string.format("images/img-%03d.%s", state.count, ext)
    state.entries[#state.entries + 1] = {
        name = "OEBPS/" .. href,
        data = data,
    }
    state.manifest[#state.manifest + 1] = string.format(
        '<item id="img_%03d" href="%s" media-type="%s"/>',
        state.count, href, media_type(local_path))
    state.by_path[local_path] = href
    return href
end

-- Rewrite absolute or relative image srcs inside a chapter body to OEBPS-relative hrefs,
-- registering the files as assets.
local function embed_body_images(body, state)
    if not body then
        return ""
    end
    return (body:gsub('src%s*=%s*"([^"]+)"', function(src)
        -- Skip already-relative srcs (non-absolute paths that don't look like local files)
        if not src:match("^/") and not src:match("^file://") then
            return 'src="' .. src .. '"'
        end
        -- Convert file:// paths to absolute paths
        local local_path = src:gsub("^file://", "")
        local href = collect_image(state, local_path)
        if href then
            return 'src="../' .. href .. '"'
        end
        return 'src=""'
    end))
end

local CSS = [[
body { line-height: 1.7; margin: 1em 4%; }
h1 { font-size: 1.3em; margin: 0 0 0.5em; }
h2 { font-size: 1.15em; margin: 0 0 0.4em; }
p { margin: 0.6em 0; text-indent: 0; }
p.meta { color: #666; font-size: 0.85em; margin: 0 0 1.2em; }
p.figcaption { color: #777; font-size: 0.85em; text-align: center; margin: 0.3em 0 1.2em; }
div.img { text-align: center; margin: 0.8em 0; }
div.img img { max-width: 100%; }
blockquote { margin: 0.8em 1em; padding: 0 0 0 0.8em; border-left: 2px solid #999; color: #444; }
sup { font-size: 0.7em; }
.img-placeholder { display: block; width: 33%; height: 180px; border: 2px solid #000; text-align: center; line-height: 180px; margin: 10px auto; }
.img-num { font-size: 1.5em; font-weight: bold; }
]]

local function chapter_document(chapter, body)
    local parts = {}
    if chapter.meta and chapter.meta ~= "" then
        parts[#parts + 1] = '<p class="meta">' .. xml_escape(chapter.meta) .. "</p>"
    end
    parts[#parts + 1] = body or ""
    return [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head>
<title>]] .. xml_escape(chapter.title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. table.concat(parts, "\n") .. [[
</body>
</html>]]
end

local function build_nav(toc)
    local parts = { "<ol>" }
    for i = 1, #toc do
        parts[#parts + 1] = '<li><a href="text/' .. toc[i].href .. '">'
            .. xml_escape(toc[i].title) .. "</a></li>"
    end
    parts[#parts + 1] = "</ol>"
    return [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Table of Contents</title></head>
<body>
<nav epub:type="toc">
]] .. table.concat(parts, "\n") .. [[
</nav>
</body>
</html>]]
end

local function build_ncx(toc, identifier, title)
    local parts = {}
    for i = 1, #toc do
        parts[#parts + 1] = string.format(
            '<navPoint id="navPoint-%d" playOrder="%d">', i, i)
            .. '<navLabel><text>' .. xml_escape(toc[i].title) .. '</text></navLabel>'
            .. '<content src="text/' .. toc[i].href .. '"/></navPoint>'
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="]] .. xml_escape(identifier) .. [["/>
<meta name="dtb:depth" content="1"/>
</head>
<docTitle><text>]] .. xml_escape(title) .. [[</text></docTitle>
<navMap>
]] .. table.concat(parts, "\n") .. [[
</navMap>
</ncx>]]
end

local CONTAINER_XML = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0"
xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile
full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]]

-- book = {
--   title, identifier, date (ISO), source (url),
--   chapters = { { title, meta, body, cover_image } , ... }
-- }
-- Builds the EPUB and returns the output path.
function EpubBuilder.build(book, out_path)
    local state = { entries = {}, manifest = {}, by_path = {}, count = 0 }
    local toc = {}
    local cover_meta = ""
    local cover_href

    -- Cover: first chapter's cover_image, registered as cover asset only
    for i = 1, #(book.chapters or {}) do
        local chapter = book.chapters[i]
        if chapter.cover_image then
            local data
            do
                local file = io.open(chapter.cover_image, "rb")
                if file then
                    data = file:read("*a")
                    file:close()
                end
            end
            if data and #data > 0 then
                local ext = chapter.cover_image:match("%.([%w]+)$") or "jpg"
                cover_href = "images/cover." .. ext
                state.entries[#state.entries + 1] = {
                    name = "OEBPS/" .. cover_href,
                    data = data,
                }
                state.manifest[#state.manifest + 1] = string.format(
                    '<item id="cover-image" href="%s" media-type="%s" properties="cover-image"/>',
                    cover_href, media_type(chapter.cover_image))
                state.by_path[chapter.cover_image] = cover_href
                cover_meta = '\n<meta name="cover" content="cover-image"/>'
            end
            break -- only the first chapter provides the cover
        end
    end

    for i = 1, #(book.chapters or {}) do
        local chapter = book.chapters[i]
        local href = string.format("ch%d.xhtml", i)
        local body = embed_body_images(chapter.body, state)
        local xhtml = chapter_document(chapter, body)
        state.entries[#state.entries + 1] = {
            name = "OEBPS/text/" .. href,
            data = xhtml,
        }
        state.manifest[#state.manifest + 1] = string.format(
            '<item id="ch%d" href="text/%s" media-type="application/xhtml+xml"/>',
            i, href)
        toc[#toc + 1] = { title = chapter.title, href = href }
    end

    local manifest_items = table.concat(state.manifest, "\n")
    local spine_items = table.concat(
        (function()
            local out = {}
            for i = 1, #(book.chapters or {}) do
                out[i] = string.format('<itemref idref="ch%d"/>', i)
            end
            return out
        end)(), "\n")

    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid"
version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">]] .. xml_escape(book.identifier) .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book.title) .. [[</dc:title>
<dc:creator>知乎</dc:creator>
<dc:publisher>知乎</dc:publisher>
<dc:language>zh-CN</dc:language>
<dc:date>]] .. xml_escape(book.date or "") .. [[</dc:date>
<meta property="dcterms:modified">]] .. utc_now() .. [[</meta>]] .. cover_meta .. [[
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="style" href="style.css" media-type="text/css"/>
]] .. manifest_items .. [[
</manifest>
<spine toc="ncx">
]] .. spine_items .. [[
</spine>
</package>]]

    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = CONTAINER_XML },
        { name = "OEBPS/content.opf", data = opf },
        { name = "OEBPS/nav.xhtml", data = build_nav(toc) },
        { name = "OEBPS/toc.ncx", data = build_ncx(toc, book.identifier, book.title) },
        { name = "OEBPS/style.css", data = CSS },
    }
    for i = 1, #state.entries do
        entries[#entries + 1] = state.entries[i]
    end
    
    local ok, err = write_file(out_path, make_zip(entries))
    if not ok then
        return nil, err
    end
    return out_path
end

EpubBuilder.make_zip = make_zip

return EpubBuilder
