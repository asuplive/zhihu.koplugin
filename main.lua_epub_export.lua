
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
    os.execute("mkdir -p '" .. export_dir .. "'")

    -- Step 3: Download all images to a temp directory
    local article_dir = export_dir .. "/epub_temp_" .. timestamp
    local images_dir = article_dir .. "/images"
    os.execute("mkdir -p '" .. images_dir .. "'")

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
        if ext == "webp" then ext = "jpg" end
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
        html_content = html_content:gsub(
            'src="' .. esc_url .. '"',
            'src="' .. filepath .. '"'
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
    os.execute("rm -rf '" .. article_dir .. "'")

    if ok and result then
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB exported to:\n%1"), epub_path),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB export failed: %1"), tostring(result)),
            timeout = 5,
        })
    end
end
