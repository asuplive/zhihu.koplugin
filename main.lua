--[[
    Zhihu Reader Plugin for KOReader v160
    - QR code login: auto-completing poll login
    - Risk-control (unhuman) verification flow for blocked networks (Android)
    - Recommended feed (batch size configurable: 6/12/18/24/30/36) with Load
      More cursor
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
    - v154: new "Refresh Mode" setting: full / partial / partial x N then full /
      Regal (default Regal). Article pictures are no longer repainted one by
      one: once the whole batch is on disk the next page turn paints them all
      in a single refresh.
    - v155: the Font Family setting now really reaches what is on screen.
      The feed list (a plain KOReader Menu) is painted with the chosen face
      instead of the menu default, article HTML gets the chosen family plus
      file-name aliases derived from the installed font files, and a local
      @font-face rule points MuPDF straight at that face. The "font applied"
      toast also reports which font file was matched, so a name that exists
      nowhere on the device is visible instead of silently ignored.
    - v156: the article CSS no longer carries an @font-face rule (MuPDF's HTML
      engine ignores it, and a rule it cannot parse is one more thing between
      the setting and the screen). The family list now starts with the font
      file name exactly as it sits on disk, extension included, because that
      is the form MuPDF's font lookup actually tries first. New "Font
      diagnostics" entry prints the resolved face, the file count and the
      exact CSS the article is laid out with.
    - v157: the family that reaches the article CSS is now the one that can
      actually draw Chinese. A Latin-only choice such as "Noto Serif" used to
      win the name match, so MuPDF drew Latin with it and left every Chinese
      character on its built-in CJK fallback -- the page looked untouched.
      Fonts are now tagged with their script coverage, a Latin-only choice is
      swapped for its CJK sibling ("Noto Serif" -> "Noto Serif CJK SC"), the
      CSS keeps only a handful of tokens instead of a hundred, and the font
      menu lists the Chinese fonts the device really has.
    - v158: v157 shipped a helper (cjkFontFaces) that was called from three
      places but never defined, so opening the font menu -- and the article
      view, which builds the same CSS -- raised "attempt to call a nil value"
      and KOReader went down; the plain text viewer kept working because it
      uses no custom CSS. The helper is now defined, font names are taken from
      the real family (not the PostScript name or the file name), a name that
      says Chinese (NotoSansCJK, DroidSansFallback, wqy-*) counts as Chinese
      even when the font metadata does not say so, and the installed font
      lookup survives a fontlist that is missing or throws.
    - v159: new "Feed Batch Size" setting. The recommended feed used to stop at
      a hard-coded 12 items; the batch is now whatever multiple of 6 the user
      picks (6 / 12 / 18 / 24 / 30 / 36, default 12). The client keeps
      accumulating API pages until the chosen size is reached, so a bigger
      batch means deeper pagination behind the same "Load More" cursor.
    - v160: the Zhihu menu is regrouped. The top level now holds only what is
      used while reading (user name, Recommended Feed, login/logout) plus four
      grouped submenus -- Reading, Layout & Refresh, Cache & Export, and
      Settings. Everything that changes how the page looks sits under Reading
      or Layout & Refresh; clearing caches and exporting sit together; feed
      batch size, a "Current Settings" summary (every value in one screen) and
      the About page sit under Settings, with About last. The About text was
      rewritten into short grouped lines (what it does / how to use it / where
      data lives) instead of one long feature list, and the version string now
      comes from a single PLUGIN_VERSION constant.
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

-- single source of truth for the version shown in About / Settings summary
local PLUGIN_VERSION  = "v160"

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
-- v159: recommended-feed batch size. Only multiples of 6 are allowed (the
-- feed list is laid out in rows of six cards per screen-worth of scrolling);
-- 12 keeps the pre-v159 behaviour.
local DEFAULT_FEED_BATCH = 12
local FEED_BATCH_STEP = 6
local FEED_BATCH_MIN = 6
local FEED_BATCH_MAX = 36
-- v140: an answer page stays cached on disk for this long (seconds).
local DEFAULT_CACHE_TTL = 3600

-- v160: the refresh-mode entries used to read two constants that were never
-- declared, so the "partial x N" label printed "Partial x nil" and no entry
-- was ticked on a fresh install. Keep N in step with PARTIAL_BEFORE_FULL in
-- article_viewer.lua.
local DEFAULT_REFRESH_MODE = "regal"
local REFRESH_PARTIAL_COUNT = 6

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
-- v157: entries are { name = family, latin_only = true }. A Latin-only family
-- ("Noto Serif") cannot draw a single Chinese character, so the menu says so
-- instead of letting the choice look broken; the CJK families come first.
local FONT_PRESETS = {
    { name = "Noto Serif CJK SC" },
    { name = "Noto Sans CJK SC" },
    { name = "Source Han Serif SC" },
    { name = "Source Han Sans SC" },
    { name = "Droid Sans Fallback" },
    { name = "WenQuanYi Micro Hei" },
    { name = "WenQuanYi Zen Hei" },
    { name = "Songti SC" },
    { name = "STSong" },
    { name = "STKaiti" },
    { name = "Heiti SC" },
    { name = "STHeiti" },
    { name = "SimSun" },
    { name = "SimHei" },
    { name = "KaiTi" },
    { name = "Microsoft YaHei" },
    { name = "PingFang SC" },
    { name = "Noto Serif", latin_only = true },
    { name = "Noto Sans", latin_only = true },
    -- generic families are left unmarked: the device decides what they map to
    { name = "serif" },
    { name = "sans-serif" },
    { name = "monospace" },
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

-- v155: article HTML is laid out by MuPDF, which resolves a CSS family name
-- against the font files the device actually ships. A family name such as
-- "Noto Serif CJK SC" almost never equals the file name it lives in
-- ("NotoSansCJK-Regular.ttc"), so on many devices the chosen family silently
-- fell back to the default stack and the setting looked like it did nothing.
-- Derive a few extra aliases from the installed font files: the name without
-- spaces, and every font file whose name matches the family.
local FONT_GENERIC_FAMILIES = { serif = true, ["sans-serif"] = true,
    monospace = true, cursive = true, fantasy = true }

-- v156: the private "ZhihuUserFont" family and its @font-face rule are gone.
-- MuPDF lays out the article HTML and it does not implement @font-face, so the
-- rule never bound a face; all it could do was sit in the stylesheet as one
-- more declaration for the parser to walk past. A real family name that MuPDF
-- can resolve is the only thing that changes the glyphs.

local function fontKey(s)
    return (tostring(s):lower():gsub("%.[%w]+$", ""):gsub("[%s%-_]", ""))
end

local function plainName(s)
    return (tostring(s):gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function baseName(path)
    return tostring(path):match("([^/\\]+)$") or tostring(path)
end

-- "./fonts/x.ttf" is relative to the KOReader data directory; MuPDF needs a
-- path it can open on its own.
local function absoluteFontPath(path)
    local p = tostring(path)
    if p:sub(1, 2) == "./" then
        local ok, DataStorage = pcall(require, "datastorage")
        if not ok or not DataStorage then return nil end
        local dir = DataStorage:getDataDir()
        if not dir then return nil end
        return dir .. "/" .. p:sub(3)
    end
    if p:sub(1, 1) == "/" then return p end
    return nil
end

-- A face carries several names: the file name, the family and the full name.
-- Only the last two are things a user types, so never take a style token such
-- as "Regular" on its own. OpenType name ids are numeric and identical across
-- platforms: 1 = family, 4 = full name.
local HB_NAME_FAMILY = 1
local HB_NAME_FULL = 4

local function faceNameTokens(face, out)
    local function add(v)
        if type(v) == "string" and v ~= "" then table.insert(out, v) end
    end
    if type(face) ~= "table" then return out end
    add(face.name)
    local names = face.names
    if type(names) ~= "table" then return out end
    for _lang, byid in pairs(names) do
        if type(byid) == "table" then
            add(byid[HB_NAME_FAMILY])
            add(byid[HB_NAME_FULL])
        elseif type(byid) == "string" then
            add(byid)
        end
    end
    return out
end

-- v157: can this face draw Chinese at all? "Noto Serif" is a Latin-only face:
-- pick it and MuPDF draws the Latin with it, but every Chinese character falls
-- back to the engine's built-in CJK face, so the article looks exactly as it
-- did before. fontlist keeps the script/language coverage HarfBuzz reports for
-- each face; the shape of those tables differs between versions, so they are
-- read defensively and nil means "cannot judge".
local CJK_SCRIPT_TAGS = { hani = true, hans = true, hant = true, jpan = true,
    kore = true, zh = true, ja = true, ko = true }

local function tagHasCJK(tag)
    if type(tag) ~= "string" then return false end
    tag = tag:lower()
    if CJK_SCRIPT_TAGS[tag] then return true end
    return tag:match("^zh") ~= nil
end

local function coverageHasCJK(t)
    if type(t) ~= "table" then return nil end
    local recognised = false
    for k, v in pairs(t) do
        if type(k) == "string" or type(v) == "string" then recognised = true end
        if tagHasCJK(k) or tagHasCJK(v) then return true end
    end
    if not recognised then return nil end
    return false
end

local function faceHasCJK(face)
    if type(face) ~= "table" then return nil end
    if type(face.scripts) == "table" and next(face.scripts) ~= nil then
        return coverageHasCJK(face.scripts)
    end
    if type(face.langs) == "table" and next(face.langs) ~= nil then
        return coverageHasCJK(face.langs)
    end
    return nil
end

-- v158: not every KOReader build keeps script coverage in fontlist.fontinfo, so
-- a name that announces Chinese (NotoSansCJK, DroidSansFallback, wqy-microhei,
-- SimSun ...) is treated as Chinese-capable when the metadata says nothing.
-- Returns nil when the name gives no clue at all: unknown is not "Latin only".
local CJK_NAME_HINTS = { "cjk", "fallback", "hei", "song", "ming", "kai",
    "wqy", "wenquanyi", "yahei", "pingfang", "fangsong", "yuanti", "simsun",
    "simhei", "sourcehan", "notosanssc", "notoserifsc", "notosansmonosc" }

local function nameLooksCJK(name)
    local key = fontKey(plainName(name))
    if key == "" then return nil end
    for _i, hint in ipairs(CJK_NAME_HINTS) do
        if key:find(hint, 1, true) then return true end
    end
    return nil
end

-- One entry per (font file, face): the file name, the family name the engine
-- reports for it, and the normalised keys of both.
local _font_faces_cache
local function installedFontFaces()
    if _font_faces_cache and #_font_faces_cache > 0 then return _font_faces_cache end
    local ok, FontList = pcall(require, "fontlist")
    if not ok or not FontList or not FontList.getFontList then return {} end
    local ok2, list = pcall(FontList.getFontList, FontList)
    if not ok2 or type(list) ~= "table" then return {} end
    local info = FontList.fontinfo
    local faces = {}
    for _i, path in ipairs(list) do
        local p = tostring(path)
        if p ~= "" then
            local families, seenfam = {}, {}
            local entries = type(info) == "table" and info[p] or nil
            -- v157: any face in the file carrying Chinese makes the file usable
            -- for Chinese text; nil means the metadata could not tell us.
            local cjk = nil
            if type(entries) == "table" then
                local known, hit = false, false
                for _j, fe in ipairs(entries) do
                    local r = faceHasCJK(fe)
                    if r ~= nil then known = true end
                    if r then hit = true end
                end
                if hit then cjk = true elseif known then cjk = false end
            end
            if type(entries) == "table" then
                for _j, face in ipairs(entries) do
                    for _k, token in ipairs(faceNameTokens(face, {})) do
                        if not seenfam[token] then
                            seenfam[token] = true
                            table.insert(families, token)
                        end
                    end
                end
            end
            local base = baseName(p)
            if #families == 0 then
                families = { (base:gsub("%.[%w]+$", "")) }
            end
            for _j, family in ipairs(families) do
                -- v158: metadata first, then the names. A file whose family is
                -- "Noto Serif" but whose file is NotoSerifCJK-Regular.ttc still
                -- counts as Chinese-capable; a bare "Noto Serif" does not.
                local file_cjk = cjk
                if file_cjk == nil then file_cjk = nameLooksCJK(family) end
                if file_cjk == nil then file_cjk = nameLooksCJK(base) end
                table.insert(faces, {
                    base = base,
                    path = p,
                    family = family,
                    key = fontKey(base),
                    family_key = fontKey(family),
                    cjk = file_cjk,
                })
            end
        end
    end
    _font_faces_cache = faces
    return faces
end

-- Every installed face that plausibly answers the requested family, best first.
-- Family name beats file name, and a regular face beats its bold/italic sibling.
local function resolveFontCandidates(name)
    local raw = plainName(name)
    if raw == "" then return {} end
    local target = fontKey(raw)
    if target == "" then return {} end
    local scored = {}
    for _i, face in ipairs(installedFontFaces()) do
        local score
        if face.family_key == target then
            score = 5
        elseif face.key == target then
            score = 4
        elseif face.family_key ~= ""
            and (face.family_key:find(target, 1, true) or target:find(face.family_key, 1, true)) then
            score = 3
        elseif face.key ~= ""
            and (face.key:find(target, 1, true) or target:find(face.key, 1, true)) then
            score = 2
        end
        if score then
            if face.key:find("bold", 1, true) or face.key:find("italic", 1, true) then
                score = score - 0.5
            end
            table.insert(scored, { face = face, score = score })
        end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    local out, seen = {}, {}
    for _i, entry in ipairs(scored) do
        if not seen[entry.face.path] then
            seen[entry.face.path] = true
            table.insert(out, entry.face)
        end
    end
    return out
end

-- v158: a face entry whose "family" is just the file name carries no real
-- family name (the font shipped no name table). Such an entry is a last resort
-- for matching, never a label to show the user or to put in the CSS.
local function faceIsFileNameToken(face)
    local family, base = face.family, face.base or ""
    if not family then return true end
    return family == base or family == (base:gsub("%.[%w]+$", ""))
end

-- v158: how much a token looks like something a human would recognise as a
-- family name. fontlist reports the PostScript name ("NotoSerifCJKsc-Regular")
-- alongside the real family ("Noto Serif CJK SC"); only the latter belongs in
-- the menu and in the CSS.
local function familyLabelScore(face)
    local f = face.family or ""
    if f == "" or faceIsFileNameToken(face) then return 0 end
    if f:find("%s") then return 3 end
    if not f:find("-", 1, true) then return 2 end
    return 1
end

-- v157: the CJK sibling of the chosen family ("Noto Serif" -> "Noto Serif CJK
-- SC"), so a Latin-only choice still ends up changing the Chinese text.
local function bestCjkFace(name)
    local target = fontKey(name)
    if target == "" then return nil end
    -- v158: prefer a face that reports a real family name; only fall back to
    -- file-name-only entries when nothing else matches.
    local best, best_score
    local best_label
    local loose
    local loose_score
    for _i, face in ipairs(installedFontFaces()) do
        if face.cjk then
            local fk = face.family_key or ""
            local score = 0
            if fk == target then
                score = 5
            elseif fk:sub(1, #target) == target then
                score = 4
            elseif fk:find(target, 1, true) then
                score = 3
            elseif target:find(fk, 1, true) then
                score = 2
            end
            if score > 0 then
                if face.key:find("bold", 1, true) or face.key:find("italic", 1, true) then
                    score = score - 0.5
                end
                local label = familyLabelScore(face)
                if label == 0 then
                    if not loose_score or score > loose_score then
                        loose, loose_score = face, score
                    end
                elseif not best_score or score > best_score
                    or (score == best_score and label > best_label) then
                    best, best_score, best_label = face, score, label
                end
            end
        end
    end
    return best or loose
end

-- v158: every installed face that can really draw Chinese, regular faces first.
-- v157 called this from three places (article CSS fallback, the font menu and
-- the diagnostics page) but never defined it, so every call raised
-- "attempt to call a nil value (global 'cjkFontFaces')" -- which is exactly why
-- opening the font menu crashed the app and the article view would not open,
-- while the plain text viewer (it uses no custom CSS) kept working.
local function cjkFontFaces()
    -- one entry per file, the best-looking label of that file
    local per_file, order = {}, {}
    for _i, face in ipairs(installedFontFaces()) do
        if face.cjk and face.base then
            local cur = per_file[face.base]
            if not cur then
                per_file[face.base] = face
                table.insert(order, face.base)
            elseif familyLabelScore(face) > familyLabelScore(cur) then
                per_file[face.base] = face
            end
        end
    end
    local out = {}
    for _i, base in ipairs(order) do
        table.insert(out, per_file[base])
    end
    table.sort(out, function(a, b)
        local ak, bk = a.key or "", b.key or ""
        local a_style = (ak:find("bold", 1, true) or ak:find("italic", 1, true)) ~= nil
        local b_style = (bk:find("bold", 1, true) or bk:find("italic", 1, true)) ~= nil
        if a_style ~= b_style then return not a_style end
        local al, bl = familyLabelScore(a), familyLabelScore(b)
        if al ~= bl then return al > bl end
        return ak < bk
    end)
    return out
end

-- v157: the family the article is really laid out with. When the chosen one
-- carries no CJK glyphs and a CJK sibling exists, the sibling wins -- otherwise
-- every Chinese character stays on the engine's fallback face and the setting
-- looks like it did nothing. Returns the family to use, the substituted face
-- (or nil) and the face the name matched before any substitution.
local effective_family_cache = {}

-- v158: the best label a single font file can be addressed by. A file such as
-- NotoSerifCJK-Regular.ttc answers to "Noto Serif CJK SC", not to the bare
-- "Noto Serif" it also reports -- asking for the bare name would land on the
-- Latin-only NotoSerif-Regular.ttf when both are installed.
local function cjkLabelOfBase(base)
    local best, best_label
    for _i, face in ipairs(installedFontFaces()) do
        if face.cjk and face.base == base then
            local label = familyLabelScore(face)
            if label > 0 and (not best_label or label > best_label) then
                best, best_label = face, label
            end
        end
    end
    return best
end

local function effectiveFontFamily(font_name)
    if not font_name or font_name == "" then return nil, nil, nil end
    local raw = plainName(font_name)
    if raw == "" or FONT_GENERIC_FAMILIES[raw:lower()] then
        return raw, nil, nil
    end
    local cached = effective_family_cache[raw]
    if cached then return cached[1], cached[2], cached[3] end
    local first = resolveFontCandidates(raw)[1]
    local out
    if first and first.cjk then
        -- v158: the chosen name already resolves to a Chinese-capable file; use
        -- that file's own family name so the CSS cannot land on a Latin-only
        -- namesake.
        local label_face = cjkLabelOfBase(first.base)
        if label_face and label_face.family ~= raw then
            out = { label_face.family, label_face, first }
        else
            out = { raw, nil, first }
        end
    else
        local sibling = bestCjkFace(raw)
        if sibling and sibling.family and sibling.family ~= "" then
            out = { sibling.family, sibling, first }
        else
            out = { raw, nil, first }
        end
    end
    effective_family_cache[raw] = out
    return out[1], out[2], out[3]
end

-- CSS tokens the layout engine can try, in order.
local function fontFamilyAliases(name, max_faces)
    local aliases = {}
    if not name or name == "" then return aliases end
    local raw = plainName(name)
    if raw == "" or FONT_GENERIC_FAMILIES[raw:lower()] then return aliases end
    local seen = {}
    local function add(token)
        if token and token ~= "" and not seen[token] then
            seen[token] = true
            table.insert(aliases, token)
        end
    end
    -- without spaces: some lookups compare the requested string against file
    -- names verbatim, where "Noto Serif CJK SC" can never match a file name
    local tight = raw:gsub("%s+", "")
    if tight ~= raw then add('"' .. tight .. '"') end
    -- v156: MuPDF resolves a family name by looking for a font file of that
    -- name, so the file name exactly as it sits on disk (extension included,
    -- e.g. "NotoSansCJK-Regular.ttc") is tried first; then the bare file name,
    -- then the family the file reports. Anything after that is a long shot.
    -- v157: earlier builds emitted every candidate (36 faces x 3 tokens), which
    -- buried the CJK-capable face and made the rule unreadable. Chinese-capable
    -- files go first, then the name matches, and only a few of each.
    local counted = 0
    local function addCandidates(list, quota)
        local used = 0
        for _i, face in ipairs(list) do
            if used >= (quota or 2) or counted >= (max_faces or 4) then return end
            used = used + 1
            counted = counted + 1
            add('"' .. face.base .. '"')
            add('"' .. (face.base:gsub("%.[%w]+$", "")) .. '"')
            if face.family and face.family ~= "" then
                add('"' .. face.family .. '"')
            end
        end
    end
    -- v158: the face the chosen name resolves to comes first -- effectiveFontFamily
    -- has already swapped a Latin-only family for its CJK sibling, so this is
    -- normally a Chinese-capable face. The device's CJK faces are only a
    -- fallback, and they must not eat the whole quota (v157 did that, so the
    -- family the user actually picked could end up outside the CSS).
    local primary = resolveFontCandidates(raw)
    if #primary == 0 then
        addCandidates(cjkFontFaces(), 3)
    else
        addCandidates(primary, 2)
        addCandidates(cjkFontFaces(), 1)
    end
    return aliases
end

-- v156: userFontFaceCss() was removed with the @font-face approach above.
-- absoluteFontPath() stays: it is the only place that turns the relative
-- "./fonts/x.ttf" form from fontlist into a path, and the diagnostics panel
-- reports it.

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
    -- v155: offer the chosen family, its file-name aliases, and then the built-in
    -- CJK stack. The engine picks the first entry it can actually resolve, while
    -- a resolvable face always wins over the fallback stack for Latin text.
    -- v157: the first family must be one that can draw Chinese. "Noto Serif" is
    -- Latin-only, so Chinese used to fall back to the built-in face and the
    -- setting looked ignored; a CJK sibling is used instead when available.
    local used_name = effectiveFontFamily(font_name)
    local families = {}
    local chosen = cssFontFamily(used_name)
    if chosen then
        table.insert(families, chosen)
        for _i, alias in ipairs(fontFamilyAliases(used_name, 4)) do
            if alias ~= chosen then table.insert(families, alias) end
        end
    end
    -- The literal choice stays last: if its file exists but no CJK sibling does,
    -- Latin text still gets exactly what was asked for.
    local original = cssFontFamily(font_name)
    if original and original ~= chosen then
        table.insert(families, original)
    end
    table.insert(families, DEFAULT_CJK_FONT_STACK)
    local family = table.concat(families, ", ")
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

-- Top level stays short: account first, then three grouped submenus,
-- then "Settings" (which holds feed batch size, the current-settings summary
-- and the About page), and Logout last.
function Zhihu:buildMenuItems()
    local sub_items = {}
    local logged_in = self.client:isLoggedIn()

    -- ---------------------------------------------------------------- account
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
    else
        table.insert(sub_items, {
            text = _("扫码登录 (Login with QR Code)"),
            callback = function() self:startQrLogin() end,
        })
    end

    -- ---------------------------------------------------------------- reading
    table.insert(sub_items, {
        text = _("阅读设置 (Reading)"),
        sub_item_table = {
            {
                text = _("字号 (Font Size)"),
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
            },
            {
                text = _("字体族 (Font Family)"),
                sub_item_table_func = function() return self:buildFontMenu() end,
            },
            {
                text = _("段落缩进 (Paragraph Indent)"),
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
            },
            {
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
            },
            {
                text = _("回答问题人头像 (Answerer Avatar)"),
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
            },
            {
                text = _("头像大小 (Avatar Size)"),
                enabled_func = function() return self:getShowAvatar() end,
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
            },
        },
    })

    -- ---------------------------------------------------------- layout/refresh
    table.insert(sub_items, {
        text = _("排版与刷新 (Layout & Refresh)"),
        sub_item_table = {
            {
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
            },
            {
                text = _("刷新模式 (Refresh Mode)"),
                sub_item_table = {
                    {text = _("全刷 (Full Refresh)"),
                     checked_func = function() return self:getRefreshMode() == "full" end,
                     callback = function()
                         self:setRefreshMode("full")
                     end},
                    {text = _("局刷 (Partial Refresh)"),
                     checked_func = function() return self:getRefreshMode() == "partial" end,
                     callback = function()
                         self:setRefreshMode("partial")
                     end},
                    {text = T(_("局部刷新 %1 次后全刷 (Partial x %1, then Full)"), REFRESH_PARTIAL_COUNT),
                     checked_func = function() return self:getRefreshMode() == "partial_n" end,
                     callback = function()
                         self:setRefreshMode("partial_n")
                     end},
                    {text = _("Regal 刷新 (Regal, Default)"),
                     checked_func = function() return self:getRefreshMode() == "regal" end,
                     callback = function()
                         self:setRefreshMode("regal")
                     end},
                },
            },
        },
    })

    -- ----------------------------------------------------------- cache/export
    table.insert(sub_items, {
        text = _("缓存与导出 (Cache & Export)"),
        sub_item_table = {
            {
                text = _("查看图片 (View Images)"),
                enabled_func = function()
                    return self.current_article ~= nil
                        and self.current_article.image_list
                        and #self.current_article.image_list > 0
                end,
                callback = function() self:showImages() end,
            },
            {
                text = _("清除图片缓存 (Clear Image Cache)"),
                callback = function() self:clearCache() end,
            },
            {
                text = _("清除页面缓存 (Clear Page Cache)"),
                callback = function() self:clearPageCache() end,
            },
            {
                text = _("导出 HTML (Export HTML)"),
                enabled_func = function() return self.current_article ~= nil end,
                callback = function() self:exportHtml() end,
            },
            {
                text = _("导出 EPUB (Export EPUB)"),
                enabled_func = function() return self.current_article ~= nil end,
                callback = function() self:exportEpub() end,
            },
        },
    })

    -- --------------------------------------------------------------- settings
    -- Feed batch size, the current-settings summary and About all live here,
    -- so the top level keeps only what is used while reading.
    table.insert(sub_items, {
        text = _("设置 (Settings)"),
        sub_item_table = {
            {
                text = _("推荐流条数 (Feed Batch Size)"),
                sub_item_table_func = function()
                    local batch_items = {}
                    for n = FEED_BATCH_MIN, FEED_BATCH_MAX, FEED_BATCH_STEP do
                        -- capture the value per iteration: every entry keeps its own n
                        local val = n
                        local label
                        if val == DEFAULT_FEED_BATCH then
                            label = T(_("%1 条（默认）/ %1 items (Default)"), val)
                        else
                            label = T(_("%1 条 / %1 items"), val)
                        end
                        table.insert(batch_items, {
                            text = label,
                            checked_func = function() return self:getFeedBatch() == val end,
                            callback = function() self:setFeedBatch(val) end,
                        })
                    end
                    return batch_items
                end,
            },
            {
                text = _("当前设置一览 (Current Settings)"),
                callback = function() self:showSettingsSummary() end,
            },
            {
                text = _("关于 (About)"),
                callback = function() self:showAbout() end,
            },
        },
    })

    if logged_in then
        table.insert(sub_items, {
            text = _("退出登录 (Logout)"),
            callback = function() self:doLogout() end,
        })
    end

    return sub_items
end

-- Current settings at a glance: answers "why does it look like this?" without
-- digging through every submenu.
function Zhihu:showSettingsSummary()
    local font_name = self:getFontName()
    local font_line
    if not font_name or font_name == "" then
        font_line = _("自动选择 (Auto)")
    else
        local used = effectiveFontFamily(font_name)
        if used and used ~= font_name then
            font_line = font_name .. " -> " .. used
        else
            font_line = font_name
        end
    end
    local lines = {
        _("【阅读】"),
        _("字号：") .. tostring(self.settings:readSetting("font_size", DEFAULT_FONT_SIZE)),
        _("字体：") .. font_line,
        _("段落缩进：") .. (self:getParaIndent() == 0 and _("不缩进") or _("缩进两个汉字")),
        _("显示图片：") .. (self.settings:readSetting("show_images", false) and _("开") or _("关")),
        _("头像：") .. (self:getShowAvatar() and _("显示") or _("隐藏"))
            .. _("，大小 ") .. tostring(self:getAvatarScale()) .. _(" 倍"),
        _("图片排版：") .. (self:getImagePageBreak() and _("单独占页") or _("上下留白")),
        _("刷新模式：") .. tostring(self:getRefreshMode()),
        "",
        _("【推荐流】"),
        _("每批条数：") .. tostring(self:getFeedBatch()) .. _(" 条"),
        "",
        _("【账号与缓存】"),
        _("登录状态：") .. (self.client:isLoggedIn() and _("已登录") or _("未登录")),
        _("页面缓存：") .. T(_("%1 分钟后过期"), math.floor(DEFAULT_CACHE_TTL / 60)),
    }
    -- TextViewer, not InfoMessage: the list is longer than the height of a
    -- small e-ink screen and must be scrollable.
    UIManager:show(TextViewer:new{
        title = _("当前设置一览 (Current Settings)"),
        text = table.concat(lines, "\n"),
    })
end

-- About page: short lines, grouped by what the user actually does.
function Zhihu:showAbout()
    local lines = {
        _("在 KOReader 上读知乎。扫码一次，之后直接翻页看推荐流和回答。"),
        "",
        _("【能做什么】"),
        _("- 扫码登录：手机确认后自动完成"),
        _("- 推荐流：每批 6~36 条可调，看完接着加载"),
        _("- 回答分页阅读，文字与图片混排"),
        _("- 图片按文章缓存，重开不再重新下载"),
        _("- 字号、字体、缩进、图片排版、刷新方式可调"),
        _("- 导出 HTML / EPUB 到本机"),
        "",
        _("【怎么用】"),
        _("- 首次使用：菜单里点「扫码登录」"),
        _("- 阅读中：左右翻页，上下滑动退出"),
        _("- 已打开的文章改了设置不会自动刷新，重新打开即可"),
        _("- 网络慢或想省电：在阅读设置里关掉「显示图片」"),
        "",
        _("【数据存放】"),
        _("- 图片缓存：数据目录 / zhihu_article_images/"),
        _("- 页面缓存：1 小时后自动过期"),
        "",
        _("项目主页：github.com/asuplive/zhihu.koplugin"),
    }
    UIManager:show(TextViewer:new{
        title = T(_("关于 (About) · 知乎阅读器 %1"), PLUGIN_VERSION),
        text = table.concat(lines, "\n"),
    })
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

    -- v155: the setting only ever reached the article CSS, so the feed itself
    -- kept the KOReader menu face. Carry it into the menu as well: the feed is
    -- the "content" the reader sees first, it has to use the chosen family.
    local feed_face = self:getUiFontFace()

    local menu = Menu:new{
        title = title,
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        font = feed_face or "smallinfofont",
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

    -- v127: fetch several pages behind the scenes and cap the list at the
    -- configured batch size; "Load More" continues from the cursor.
    -- v159: both the item cap and the page budget follow the "Feed Batch Size"
    -- setting (6 / 12 / 18 / 24 / 30 / 36 -- multiples of 6), 12 by default.
    local batch = self:getFeedBatch()
    local pages = self:feedPagesForBatch(batch)
    local items, next_url = self.client:getRecommendFeed(start_url, pages, batch)
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
    -- v155: the resolved UI face is cached per name, drop it on any change
    self._ui_face_cache = nil
    -- v157: so is the family the article is laid out with
    effective_family_cache = {}
    self.updated = true
end

-- v155: the feed list is a plain KOReader Menu and painted with its own face,
-- so it ignored the Font Family setting entirely. Resolve the chosen family to
-- an installed font file that ui/font can really load, and only return a name
-- after Font:getFace() has accepted it (a bad name would make the menu crash).
function Zhihu:getUiFontFace()
    local name = self:getFontName()
    if not name then return nil end
    if FONT_GENERIC_FAMILIES[name:lower()] then return nil end
    local cache = self._ui_face_cache
    if cache and cache.name == name then return cache.face end

    -- v157: a Latin-only family ("Noto Serif") would render every Chinese
    -- title in the feed as tofu boxes, so load its CJK sibling instead.
    local lookup = effectiveFontFamily(name) or name
    -- installed candidates first (best score first), then whatever the user
    -- typed, so a font that is not in the scan list can still be tried
    local candidates = {}
    for _i, installed in ipairs(resolveFontCandidates(lookup)) do
        table.insert(candidates, installed.base)
    end
    table.insert(candidates, lookup)
    if lookup ~= name then table.insert(candidates, name) end

    local face = nil
    for _i, candidate in ipairs(candidates) do
        local ok, got = pcall(Font.getFace, Font, candidate, 20)
        if ok and got then
            face = candidate
            break
        end
    end
    self._ui_face_cache = { name = name, face = face }
    return face
end

-- v148: should a content picture start on a page of its own?
function Zhihu:getImagePageBreak()
    return self.settings:readSetting("image_page_break", DEFAULT_IMAGE_PAGE_BREAK) == true
end

-- v154: which e-ink refresh strategy the article viewer uses
-- ("full" / "partial" / "partial_n" / "regal", default "regal").
function Zhihu:getRefreshMode()
    local v = self.settings:readSetting("refresh_mode", DEFAULT_REFRESH_MODE)
    if v == "full" or v == "partial" or v == "partial_n" or v == "regal" then
        return v
    end
    return DEFAULT_REFRESH_MODE
end

function Zhihu:setRefreshMode(mode)
    if mode ~= "full" and mode ~= "partial" and mode ~= "partial_n" and mode ~= "regal" then
        mode = DEFAULT_REFRESH_MODE
    end
    self.settings:saveSetting("refresh_mode", mode)
    self.updated = true
    local labels = {
        full = _("Full refresh"),
        partial = _("Partial refresh"),
        partial_n = T(_("Partial x %1, then full"), REFRESH_PARTIAL_COUNT),
        regal = _("Regal refresh"),
    }
    UIManager:show(InfoMessage:new{
        text = T(_("Refresh mode: %1"), labels[mode] or mode),
        timeout = 2,
    })
end

-- v159: how many items one recommended-feed batch holds. Always a multiple of
-- FEED_BATCH_STEP, clamped to [FEED_BATCH_MIN, FEED_BATCH_MAX]; a missing or
-- unusable stored value falls back to the old hard-coded 12.
function Zhihu:getFeedBatch()
    local v = tonumber(self.settings:readSetting("feed_batch", DEFAULT_FEED_BATCH))
    if not v or v ~= v then v = DEFAULT_FEED_BATCH end -- nil / NaN guard
    v = math.floor(v / FEED_BATCH_STEP + 0.5) * FEED_BATCH_STEP
    if v < FEED_BATCH_MIN then
        v = FEED_BATCH_MIN
    elseif v > FEED_BATCH_MAX then
        v = FEED_BATCH_MAX
    end
    return v
end

function Zhihu:setFeedBatch(n)
    n = math.floor((tonumber(n) or DEFAULT_FEED_BATCH) / FEED_BATCH_STEP + 0.5) * FEED_BATCH_STEP
    if n < FEED_BATCH_MIN then
        n = FEED_BATCH_MIN
    elseif n > FEED_BATCH_MAX then
        n = FEED_BATCH_MAX
    end
    self.settings:saveSetting("feed_batch", n)
    self.updated = true
    UIManager:show(InfoMessage:new{
        text = T(_("Feed batch size: %1 items"), n),
        timeout = 2,
    })
end

-- v159: how many API pages to walk before a batch of `n` items can be full.
-- Each page carries 20 raw cards, but video / promotion / live / roundtable
-- cards are dropped, so only a fraction survives: 3 pages used to be enough
-- for the old 12-item batch, hence one extra page per extra 4 items.
function Zhihu:feedPagesForBatch(n)
    return math.max(3, math.ceil(n / 4))
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

-- v155: say what the chosen family resolved to on THIS device. The old message
-- only claimed the setting was saved, so a name that matched no font file looked
-- identical to a working one - which is why "the font does not apply" was
-- impossible to diagnose from the device itself.
function Zhihu:_fontMatchHint(name)
    if not name then return _("使用内置中文字体栈") end
    if FONT_GENERIC_FAMILIES[name:lower()] then
        return _("通用字体族，由系统决定具体字体")
    end
    local candidates = resolveFontCandidates(name)
    -- v157: a matched file is not the same as a matched file that can draw
    -- Chinese -- "Noto Serif" matches 36 faces and still changes nothing.
    local used, sibling = effectiveFontFamily(name)
    local lines = {}
    if sibling then
        table.insert(lines, T(_("「%1」不含汉字字形，正文改用 %2"), name, used))
    end
    if #candidates > 0 then
        local face = candidates[1]
        if face.family and face.family ~= "" and face.family ~= face.base then
            table.insert(lines, T(_("已匹配字体文件：%1（%2）"), face.base, face.family))
        else
            table.insert(lines, T(_("已匹配字体文件：%1"), face.base))
        end
    else
        table.insert(lines, _("本机字体目录未找到同名文件，将按字体名交给渲染引擎"))
    end
    return table.concat(lines, "\n")
end

function Zhihu:_showFontApplied(name)
    UIManager:show(InfoMessage:new{
        text = T(_("字体：%1（重新打开文章/推荐流生效）"), name)
            .. "\n" .. self:_fontMatchHint(name)
            .. "\n" .. _("若正文仍是默认字体，请点「字体诊断」"),
        timeout = 3,
    })
end

-- v156: what the layout engine is actually handed on THIS device. The toast
-- could only say "a font file was matched", which is not the same thing as
-- "the engine drew with it": the article is laid out by MuPDF, which resolves
-- a family name against its own font search path and ignores @font-face. This
-- panel prints the resolved face, the file count and the final CSS, so a bad
-- family name can be told apart from an engine that will not take a custom
-- face at all -- instead of another round of "it still does not work".
function Zhihu:showFontDiagnostics()
    local name = self:getFontName()
    local lines = {}
    table.insert(lines, T(_("设置字体 / Setting: %1"), name or _("默认 / default")))

    local ok_engine, Mupdf = pcall(require, "mupdf")
    if ok_engine and Mupdf then
        local ver = nil
        if type(Mupdf.version) == "function" then
            local ok_v, v = pcall(Mupdf.version)
            if ok_v then ver = v end
        elseif Mupdf.version ~= nil then
            ver = Mupdf.version
        end
        if ver then table.insert(lines, T(_("渲染引擎 / Engine: MuPDF %1"), tostring(ver)))
        else table.insert(lines, _("渲染引擎 / Engine: MuPDF")) end
    end

    local ok_list, FontList = pcall(require, "fontlist")
    if ok_list and FontList and FontList.getFontList then
        local ok_2, list = pcall(FontList.getFontList, FontList)
        if ok_2 and type(list) == "table" then
            table.insert(lines, T(_("设备字体文件数 / Font files: %1"), #list))
        end
    end

    if name and not FONT_GENERIC_FAMILIES[name:lower()] then
        local cands = resolveFontCandidates(name)
        -- v157: which family is really used, and can it draw Chinese at all?
        local used, sibling, first = effectiveFontFamily(name)
        local chosen_cjk = first and first.cjk
        local cjk_text = _("未知 / unknown")
        if chosen_cjk == true then cjk_text = _("是 / yes")
        elseif chosen_cjk == false then cjk_text = _("否 / no") end
        table.insert(lines, T(_("所选族名含汉字 / Chosen family has CJK: %1"), cjk_text))
        table.insert(lines, T(_("正文实际字体 / Family used: %1"), tostring(used)))
        if sibling then
            table.insert(lines, T(_("  （已自动换成含汉字的同族字体：%1）"), sibling.base))
        end
        local cjk_faces = cjkFontFaces()
        table.insert(lines, T(_("设备含汉字字体文件数 / CJK-capable files: %1"), #cjk_faces))
        table.insert(lines, T(_("匹配候选 / Matching faces: %1"), #cands))
        for i = 1, math.min(#cands, 5) do
            local face = cands[i]
            local tag = _("未知")
            if face.cjk == true then tag = _("含中文")
            elseif face.cjk == false then tag = _("仅西文") end
            table.insert(lines, string.format("  %d) [%s] %s | %s", i, tag,
                tostring(face.base), tostring(face.family or "?")))
            local abs = absoluteFontPath(face.path)
            if abs then table.insert(lines, "     " .. abs) end
        end
        if #cands == 0 then
            table.insert(lines, _("  （本机找不到该字体的文件）"))
        end
    end

    table.insert(lines, _("正文 CSS / Article CSS:"))
    local css = buildArticleCss(name, self:getParaIndent())
    local family = css:match("font%-family:%s*([^;]+);") or "(none)"
    table.insert(lines, "  " .. family)

    UIManager:show(TextViewer:new{
        title = _("字体诊断 / Font diagnostics"),
        text = table.concat(lines, "\n"),
        text_face = Font:getFace("cfont", 18),
        justified = false,
    })
end

-- v157: the families on THIS device that can actually draw Chinese, so the
-- user can pick one that exists instead of typing a name that does not.
function Zhihu:_deviceCjkFontNames()
    local seen, out = {}, {}
    for _i, face in ipairs(cjkFontFaces()) do
        local fam = face.family
        if fam and fam ~= "" and not seen[fam] then
            seen[fam] = true
            table.insert(out, fam)
        end
    end
    table.sort(out)
    return out
end

function Zhihu:buildFontMenu()
    local items = {}
    table.insert(items, {
        text = _("默认（内置中文字体栈）/ Default"),
        checked_func = function() return self:getFontName() == nil end,
        callback = function()
            self:setFontName(nil)
            UIManager:show(InfoMessage:new{
                text = _("字体：默认（重新打开文章/推荐流生效）"),
                timeout = 3,
            })
        end,
    })
    table.insert(items, {text = "----------------"})

    for _idx, preset in ipairs(FONT_PRESETS) do
        local pname = preset.name
        local label = pname
        if preset.latin_only then
            label = T(_("%1（仅西文） / (Latin only)"), pname)
        end
        table.insert(items, {
            text = label,
            checked_func = function() return self:getFontName() == pname end,
            callback = function()
                self:setFontName(pname)
                self:_showFontApplied(pname)
            end,
        })
    end

    -- v157: whatever Chinese-capable families the device really has, one tap away.
    local cjk_fonts = self:_deviceCjkFontNames()
    if #cjk_fonts > 0 then
        table.insert(items, {text = "----------------"})
        table.insert(items, {
            text = T(_("设备上的中文字体（%1）/ Chinese fonts on device"), #cjk_fonts),
            sub_item_table_func = function()
                local sub = {}
                for _i, fam in ipairs(cjk_fonts) do
                    table.insert(sub, {
                        text = fam,
                        checked_func = function() return self:getFontName() == fam end,
                        callback = function()
                            self:setFontName(fam)
                            self:_showFontApplied(fam)
                        end,
                    })
                end
                return sub
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
                if preset.name == n then return false end
            end
            return true
        end,
        callback = function() self:showFontInput() end,
    })
    -- v156: one tap to see what the article is really laid out with
    table.insert(items, {text = "----------------"})
    table.insert(items, {
        text = _("字体诊断（正文为何没变） / Font diagnostics"),
        callback = function() self:showFontDiagnostics() end,
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
                            UIManager:show(InfoMessage:new{
                                text = _("字体：默认（重新打开文章/推荐流生效）"),
                                timeout = 3,
                            })
                        else
                            self:setFontName(value)
                            self:_showFontApplied(value)
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