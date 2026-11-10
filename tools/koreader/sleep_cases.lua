-- Cases of tools/koreader/check_sleep.lua. The timers (the server tick and the zip) exist only while the
-- session runs, so the screen starts a real one, on the Wi-Fi address of the computer, for the few seconds
-- of the check. Nobody is approved: the approval needs a tap on the screen. Without a private network, the
-- screen shows the "no local network" message and has no timers to check.
require("book_drop/lan").install("book_drop")
require("book_drop/awake").install("book_drop")

local DataStorage = require("datastorage")
local out_dir = assert(os.getenv("OUTPUT_DIR"))
os.execute(string.format("mkdir -p '%s/books' '%s/shots' '%s/cache'", out_dir, out_dir, DataStorage:getDataDir()))
local shot = io.open(out_dir .. "/shots/shot.png", "wb")
shot:write("\137PNG\r\n\26\n")
shot:close()

local function sharing()
    local Screen = require("book_drop/ui/screen")
    local screen = Screen:new{ books_dir = out_dir .. "/books", screenshot_dir = out_dir .. "/shots" }
    if not screen.server then
        print("note book_drop/ui/screen: no private network here, so the session did not start")
    end
    return screen
end

return {
    ["book_drop/ui/screen"] = sharing,
    ["screen building the zip"] = function()
        local screen = sharing()
        if screen.server then
            screen:zip_status()
        end
        return screen
    end,
}
