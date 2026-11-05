-- Serves a demo library for the README screenshots and renders the screens of the device.
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
os.execute('mkdir -p "' .. DataStorage:getDataDir() .. '/cache"')
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
require("ui/uimanager"):init()
local DropScreen = require("book_drop/ui/screen")

local out = assert(os.getenv("SHOT_DIR"))
local function shot(screen, name)
    screen:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out .. "/" .. name .. ".png")
end
local screen = DropScreen:new{
    screenshot_dir = assert(os.getenv("SHOTS_DIR")),
    books_dir = assert(os.getenv("BOOKS_DIR")),
    language = os.getenv("UI_LANGUAGE") or "en",
    open_firewall = function() end,
    close_firewall = function() end,
}
assert(screen.url, "no address")
local url = screen.url
-- The pictures show an example address, not the one of the machine that made them.
screen.url = "http://192.168.0.42:8642/k7m2xq9pt4wnc3rh/"
screen:show_sharing()
shot(screen, "device_waiting")
screen.state = "connected"
screen.access.client_ip = "192.168.0.20"
screen.received = 3
screen.activity = string.format(screen.strings.last_received, "Helena Vargas - The House of Tides.epub")
screen:show_sharing()
shot(screen, "device_connected")
screen.access.client_ip = nil
screen.state = "waiting"
screen.received = 0
screen.activity = nil
screen.url = url
local ready = io.open(assert(os.getenv("READY_FILE")), "w")
ready:write(url)
ready:close()
local started = os.time()
local run_seconds = tonumber(os.getenv("RUN_SECONDS")) or 0
while os.time() - started < run_seconds do
    screen.server:tick()
    if screen.access.pending_ip then
        screen.access:approve(screen.access.pending_ip)
    end
    require("ffi/util").usleep(2000)
end
screen:onCloseWidget()
os.exit(0)
