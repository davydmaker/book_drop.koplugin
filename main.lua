local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local I18n = require("book_drop/i18n")
local PluginScreensaver = require("book_drop/screensaver")
local Screen = require("book_drop/ui/screen")

PluginScreensaver.install(debug.getinfo(1, "S").source:gsub("^@", ""):match("(.*)/") or ".")

local BookDrop = WidgetContainer:extend{
    name = "book_drop",
    is_doc_only = false,
}

local recovered = false

function BookDrop:init()
    self.ui.menu:registerToMainMenu(self)
    if not recovered then
        recovered = true
        Screen.recover(G_reader_settings:readSetting("home_dir") or Device.home_dir)
    end
end

function BookDrop:addToMainMenu(menu_items)
    menu_items.book_drop = {
        text = I18n[I18n.language_from(G_reader_settings:readSetting("language"))].title,
        sorting_hint = "tools",
        callback = function()
            local Screenshoter = require("ui/widget/screenshoter")
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenConnected(function()
                UIManager:show(Screen:new{
                    screenshot_dir = Screenshoter:getScreenshotDir(),
                    books_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir,
                })
            end)
        end,
    }
end

return BookDrop
