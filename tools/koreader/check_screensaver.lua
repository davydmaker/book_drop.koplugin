-- Checks when the plugin cover replaces the sleep screen image, and saves the resulting screen.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_screensaver.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
G_reader_settings:saveSetting("screensaver_type", "cover")
G_reader_settings:saveSetting("screensaver_img_background", "black")
package.path = plugin_dir .. "/?.lua;" .. package.path

local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
-- Screensaver needs a ReaderUI or FileManager instance; without a last book it falls back to the KOReader logo.
require("apps/filemanager/filemanager").instance = {}

local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screensaver = require("ui/screensaver")
local PluginScreensaver = require("book_drop/screensaver")

PluginScreensaver.install(plugin_dir)
PluginScreensaver.install(plugin_dir)

-- Stand-ins with the name and flag of each real screen class, so the check does not depend on accounts, data or network.
local SCREEN_MODULES = { "book_drop/ui/screen" }

local plugin_image = plugin_dir .. "/assets/screensaver.png"
local default_image = "resources/koreader.png"
local failures = 0

local function report(ok, label, detail)
    print(string.format("%s %s: %s", ok and "ok" or "FAILED", label, detail))
    if not ok then
        failures = failures + 1
    end
end

local function check(label, event, expected_file)
    Screensaver:setup(event)
    local file, kind = Screensaver.image_file, Screensaver.screensaver_type
    local ok = file == expected_file and (expected_file ~= plugin_image or kind == "cover")
    report(ok, label, string.format("%s (%s)", tostring(file), tostring(kind)))
    Screensaver:cleanup()
end

local function stand_in(module)
    local class = require(module)
    return InputContainer:new{ name = class.name, covers_fullscreen = class.covers_fullscreen }
end

check("no plugin screen open", nil, default_image)

for _, module in ipairs(SCREEN_MODULES) do
    local screen = stand_in(module)
    UIManager:show(screen)
    check(string.format("with %s open", tostring(screen.name)), nil, plugin_image)
    UIManager:close(screen)
end

local screen = stand_in(SCREEN_MODULES[1])
UIManager:show(screen)
check("powering off with the plugin open", "poweroff", default_image)

local dialog = InfoMessage:new{ text = "Message" }
UIManager:show(dialog)
check("with a dialog over the plugin", nil, plugin_image)
UIManager:close(dialog)

local other = InputContainer:new{ name = "other_fullscreen", covers_fullscreen = true }
UIManager:show(other)
check("with another full-screen window over the plugin", nil, default_image)
UIManager:close(other)

Screensaver:setup()
Screensaver:show()
local painted = false
for widget in UIManager:topdown_widgets_iter() do
    if widget.name == "ScreenSaver" then
        Screen.bb:fill(require("ffi/blitbuffer").COLOR_WHITE)
        widget:paintTo(Screen.bb, 0, 0)
        Screen.bb:writePNG(out_dir .. "/screensaver.png")
        painted = true
        break
    end
end
report(painted, "sleep screen painted", out_dir .. "/screensaver.png")
Screensaver:close_widget()
Screensaver:cleanup()
Device.screen_saver_mode = false

G_reader_settings:saveSetting("screensaver_type", "random_image")
check("sleep screen mode other than cover", nil, default_image)
G_reader_settings:saveSetting("screensaver_type", "cover")

UIManager:close(screen)
check("after closing the plugin", nil, default_image)

os.exit(failures == 0 and 0 or 1)
