--[[
    Zhihu Reader Plugin for KOReader v37
    - QR code login: ImageViewer with QR image (fullscreen=true, TextViewer fallback)
    - Recommended feed with refresh button
    - TextViewer for reading (page turn by tap)
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

local ZhihuClient = require("zhihu_client")

local DEFAULT_FONT_SIZE = 22

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
        text = _("About"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Zhihu Reader v37\n\n- QR code login\n- Recommended feed with refresh\n- TextViewer reading"),
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

    local loading = InfoMessage:new{text = _("Getting QR code..."), timeout = 0}
    UIManager:show(loading)

    local token, err = self.client:getQrCodeToken()
    UIManager:close(loading)

    if not token then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed: %1"), tostring(err or "unknown")),
            timeout = 5,
        })
        return
    end

    self.pending_token = token

    -- Try to show QR image with ImageViewer
    local qr_path = DataStorage:getDataDir() .. "/zhihu_qr.png"
    local dl_ok = self.client:downloadQrImage(token, qr_path)

    if dl_ok then
        local iv_ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
        local ri_ok, RenderImage = pcall(require, "ui/renderimage")

        if iv_ok and ri_ok then
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
    self.cached_user_name = nil
    self.pending_token = nil
    UIManager:show(InfoMessage:new{text = _("Logged out."), timeout = 3})
end

-- =========================================================================
-- Recommended Feed (with refresh button)
-- =========================================================================

function Zhihu:showRecommendFeed()
    if not self.client:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please login first.\n\nUse QR code login."),
            timeout = 5,
        })
        return
    end
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{text = _("Device is offline."), timeout = 3})
        return
    end

    self:_loadRecommendFeed(0)
end

function Zhihu:_loadRecommendFeed(offset)
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
        table.insert(menu_items, {
            text = text,
            question_id = item.question_id,
            question_title = item.title,
            item_type = item.item_type or "answer",
            item_content = item.content,
            item_author = item.author,
            item_voteup = item.voteup,
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

        -- v35: Do NOT close menu - TextViewer overlays on top
        -- so when TextViewer closes, user is back at the list
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
-- Read Article (TextViewer)
-- =========================================================================

function Zhihu:showArticle(question_id, title, item_type)
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{text = _("Device is offline."), timeout = 3})
        return
    end

    local loading = InfoMessage:new{
        text = T(_("Loading: %1"), title and #title > 30 and title:sub(1, 30) .. "..." or (title or "")),
        timeout = 0,
    }
    UIManager:show(loading)

    local text, err = self.client:getAnswers(question_id, title, item_type)
    UIManager:close(loading)

    if not text then
        local diag = tostring(err or "unknown")
        local last_err = self.client:getLastError() or ""
        if last_err ~= "" then diag = diag .. "\n(" .. last_err .. ")" end
        UIManager:show(InfoMessage:new{text = T(_("Load failed: %1"), diag), timeout = 8})
        return
    end

    local font_size = self.settings:readSetting("font_size", DEFAULT_FONT_SIZE)
    UIManager:show(TextViewer:new{
        title = title or "",
        text = text,
        text_face = Font:getFace("cfont", font_size),
        justified = true,
    })
end

return Zhihu
