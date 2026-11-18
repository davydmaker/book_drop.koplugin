-- Opens every state of the screen in every language and checks that it fits the height of the screen, with
-- the longest texts each state can show. Run it in four screen sizes with tools/koreader/check_all_sizes.sh.
-- The session is not started: the screen opens with an address outside a private network, and the states
-- with a code are filled in by hand, so nothing listens on the network of the computer.
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
require("book_drop/lan").install("book_drop")
require("book_drop/awake").install("book_drop")
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local DropScreen = require("book_drop/ui/screen")

os.execute(string.format("mkdir -p '%s/books' '%s/shots'", out_dir, out_dir))

local LONG_URL = "http://192.168.255.255:8642/abcdefghjkmnpqrs/"
local LONG_IP = "192.168.255.255"
local LONG_BOOK = string.rep("Uma coleção de títulos muito longos ", 4) .. ".epub"

local problems = 0
local function problem(text)
    problems = problems + 1
    print("PROBLEM: " .. text)
end
local function check(screen, name)
    UIManager:forceRePaint()
    Screen.bb:writePNG(out_dir .. "/" .. name .. ".png")
    if screen.content_height > Screen:getHeight() then
        problem(string.format("%s taller than the screen: %d > %d", name, screen.content_height, Screen:getHeight()))
    end
end

for _, language in ipairs({ "en", "pt", "es" }) do
    local screen = DropScreen:new{ books_dir = out_dir .. "/books", screenshot_dir = out_dir .. "/shots", language = language, local_ip = "127.0.0.1" }
    UIManager:show(screen)
    local s = screen.strings
    check(screen, "no_network_" .. language)
    for _, key in ipairs({ "slept", "idle_stop", "firewall_failed", "token_failed", "draw_failed" }) do
        screen:show_message(s.ended_title, s[key])
        check(screen, "message_" .. key .. "_" .. language)
    end
    screen.url = LONG_URL
    screen.received = 9999
    screen.book_count = 99999
    screen.state = "waiting"
    screen:show_sharing()
    check(screen, "waiting_" .. language)
    screen.access = { client_ip = LONG_IP }
    screen.state = "connected"
    for _, activity in ipairs({ string.format(s.receiving, LONG_BOOK), string.format(s.last_received, LONG_BOOK), s.zip_preparing }) do
        screen.activity = activity
        screen:show_sharing()
        check(screen, "connected_" .. language)
    end
    UIManager:close(screen)
end

-- The refresh modes, read where KOReader reads them: the first paint of each layout flashes, a change of text in
-- the same layout does not, the update after eight of those flashes again, and so does the first after waking up.
local modes = {}
local real_set_dirty = UIManager.setDirty
UIManager.setDirty = function(manager, widget, refresh, ...)
    if type(refresh) == "function" then
        local read = refresh
        refresh = function()
            local mode, region = read()
            modes[#modes + 1] = mode
            return mode, region
        end
    end
    return real_set_dirty(manager, widget, refresh, ...)
end
local screen = DropScreen:new{ books_dir = out_dir .. "/books", screenshot_dir = out_dir .. "/shots", language = "en", local_ip = "127.0.0.1" }
UIManager:show(screen)
UIManager:forceRePaint()
screen.url = LONG_URL
screen.state = "waiting"
for _ = 1, 10 do
    screen:show_sharing()
    UIManager:forceRePaint()
end
screen:onResume()
screen:show_sharing()
UIManager:forceRePaint()
local expected = "full,full,ui,ui,ui,ui,ui,ui,ui,ui,full,full"
if table.concat(modes, ",") ~= expected then
    problem("refresh modes: expected " .. expected .. ", got " .. table.concat(modes, ","))
end
UIManager.setDirty = real_set_dirty

-- An error drawing a name from another device gives way to a message without it, with the session stopped.
local TextBoxWidget = require("ui/widget/textboxwidget")
local real_paint = TextBoxWidget.paintTo
TextBoxWidget.paintTo = function(widget, ...)
    if tostring(widget.text):find("BROKEN NAME", 1, true) then
        error("planted failure")
    end
    return real_paint(widget, ...)
end
screen.access = { client_ip = LONG_IP }
screen.state = "connected"
screen.activity = string.format(screen.strings.last_received, "BROKEN NAME.epub")
screen:show_sharing()
local painted = pcall(UIManager.forceRePaint, UIManager)
TextBoxWidget.paintTo = real_paint
if not painted then
    problem("a failed paint escaped to KOReader")
elseif screen.state ~= "message" or screen.server then
    problem("a failed paint did not give way to the message")
end
check(screen, "paint_failed_en")
UIManager:close(screen)

-- The same with the approval question open on top, which must not be closed while KOReader is painting.
screen = DropScreen:new{ books_dir = out_dir .. "/books", screenshot_dir = out_dir .. "/shots", language = "en", local_ip = "127.0.0.1" }
UIManager:show(screen)
screen.url = LONG_URL
screen.access = { client_ip = LONG_IP }
screen.state = "connected"
screen.activity = string.format(screen.strings.last_received, "BROKEN NAME.epub")
screen:ask_permission(LONG_IP)
local confirm = screen.confirm
TextBoxWidget.paintTo = function(widget, ...)
    if tostring(widget.text):find("BROKEN NAME", 1, true) then
        error("planted failure")
    end
    return real_paint(widget, ...)
end
screen:show_sharing()
painted = pcall(UIManager.forceRePaint, UIManager)
TextBoxWidget.paintTo = real_paint
UIManager:_checkTasks()
if not painted then
    problem("a failed paint with the approval question open escaped to KOReader")
elseif UIManager:isWidgetShown(confirm) then
    problem("the approval question stayed open after a failed paint")
end
UIManager:close(screen)

print(problems == 0 and "layout: ok" or ("layout: " .. problems .. " problem(s)"))
os.exit(problems == 0 and 0 or 1)
