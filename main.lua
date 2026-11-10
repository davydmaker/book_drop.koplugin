local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local I18n = require("book_drop/i18n")
local PluginScreensaver = require("book_drop/screensaver")
local Screen = require("book_drop/ui/screen")

-- When the file loads, so a crash with the screen open is undone as soon as KOReader starts again.
require("book_drop/lan").install("book_drop")
require("book_drop/awake").install("book_drop")
PluginScreensaver.install(debug.getinfo(1, "S").source:gsub("^@", ""):match("(.*)/") or ".", "book_drop")

local BookDrop = WidgetContainer:extend{
    name = "book_drop",
    is_doc_only = false,
}

local recovered = false

local function strings()
    return I18n[I18n.language_from(G_reader_settings:readSetting("language"))]
end

function BookDrop:init()
    self.ui.menu:registerToMainMenu(self)
    if not recovered then
        recovered = true
        Screen.recover(G_reader_settings:readSetting("home_dir") or Device.home_dir)
    end
end

function BookDrop:addToMainMenu(menu_items)
    menu_items.book_drop = {
        text = strings().title,
        sorting_hint = "tools",
        callback = function()
            local Screenshoter = require("ui/widget/screenshoter")
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenConnected(function()
                local ok, screen = pcall(Screen.new, Screen, {
                    screenshot_dir = Screenshoter:getScreenshotDir(),
                    books_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir,
                })
                if ok then
                    UIManager:show(screen)
                else
                    logger.warn("Book Drop: could not open", screen)
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{ text = strings().open_failed })
                end
            end)
        end,
    }
end

return BookDrop
