local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local shots = assert(os.getenv("SHOTS_DIR"))
local ready = assert(os.getenv("READY_FILE"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
-- What main.lua does when it loads.
require("book_drop/lan").install("book_drop")
require("book_drop/awake").install("book_drop")
os.execute('mkdir -p "' .. DataStorage:getDataDir() .. '/cache"')
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local ShareScreen = require("book_drop/ui/screen")

local screen = ShareScreen:new{ screenshot_dir = shots, books_dir = assert(os.getenv("BOOKS_DIR")), language = os.getenv("UI_LANGUAGE") or "en" }
assert(screen.url, "no address: " .. tostring(screen.state))
print("keeps awake on opening: " .. tostring(require("pluginshare").pause_auto_suspend == true))
assert(screen.content_height <= Screen:getHeight(), "screen overflow: " .. screen.content_height)
screen:paintTo(Screen.bb, 0, 0)
if os.getenv("OUTPUT_DIR") then Screen.bb:writePNG(os.getenv("OUTPUT_DIR") .. "/waiting.png") end
local file = io.open(ready, "w")
file:write(screen.url)
file:close()
local started = os.time()
local last_received = 0
while os.time() - started < tonumber(os.getenv("RUN_SECONDS") or 25) do
    -- The tasks KOReader would run: the server tick and the zip, which is built outside the requests.
    UIManager:_checkTasks()
    if not screen.server then break end
    if screen.received ~= last_received then
        last_received = screen.received
        assert(screen.content_height <= Screen:getHeight(), "screen overflow: " .. screen.content_height)
        if os.getenv("OUTPUT_DIR") then
            screen:paintTo(Screen.bb, 0, 0)
            Screen.bb:writePNG(os.getenv("OUTPUT_DIR") .. "/received.png")
        end
    end
    if screen.access.pending_ip then
        local ip = screen.access.pending_ip
        local signal = io.open(os.getenv("APPROVE_FILE"), "rb")
        if signal then
            signal:close()
            screen.access:approve(ip)
            screen.state = "connected"
            screen:show_sharing()
            screen:paintTo(Screen.bb, 0, 0)
            if os.getenv("OUTPUT_DIR") then Screen.bb:writePNG(os.getenv("OUTPUT_DIR") .. "/connected.png") end
            print("approved: " .. ip)
        end
    end
    require("ffi/util").usleep(2000)
end
local open_connections = screen.server and #screen.server.connections or 0
screen:onCloseWidget()
print("connections on closing: " .. open_connections)
print("received: " .. screen.received)
print("keeps awake after closing: " .. tostring(require("pluginshare").pause_auto_suspend == true))
local zip_left = io.open(screen.zip_path, "rb")
print("temporary zip left: " .. tostring(zip_left ~= nil))
local probe = require("socket").connect(screen.ip, 8642)
print("port closed after closing: " .. tostring(probe == nil))
os.exit(0)
