-- Random touches on every state of the screen, in every language. The session is not started: the screen
-- opens with an address outside a private network, and the states with a code are filled in by hand, so
-- nothing listens on the network of the computer. The approval question is opened as a new device would.
-- Usage: KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/fuzz_ui.lua
local Fuzz = dofile(os.getenv("PLUGIN_DIR") .. "/tools/koreader/fuzz.lua")
require("book_drop/lan").install("book_drop")
require("book_drop/awake").install("book_drop")
local UIManager = require("ui/uimanager")
local Screen = require("book_drop/ui/screen")

local out_dir = assert(os.getenv("OUTPUT_DIR"))
os.execute(string.format("mkdir -p '%s/books' '%s/shots'", out_dir, out_dir))

local function open(language, state)
    local screen = Screen:new{ books_dir = out_dir .. "/books", screenshot_dir = out_dir .. "/shots", language = language, local_ip = "127.0.0.1" }
    if state ~= "message" then
        screen.url = "http://192.168.0.42:8642/abcdefghjkmnpqrs/"
        screen.access = { client_ip = "192.168.0.20" }
        screen.state = state == "approval" and "waiting" or state
        screen:show_sharing()
    end
    UIManager:show(screen)
    if state == "approval" then
        screen:ask_permission("192.168.0.20")
    end
    return screen
end

local fuzz = Fuzz.new{ screen = open("en", "message") }
for _, language in ipairs({ "en", "pt", "es" }) do
    for _, state in ipairs({ "message", "waiting", "connected", "approval" }) do
        fuzz:run{
            label = state .. " " .. language,
            setup = function(f)
                f:close_above()
                UIManager:close(f.screen)
                return open(language, state)
            end,
        }
    end
end
fuzz:finish()
