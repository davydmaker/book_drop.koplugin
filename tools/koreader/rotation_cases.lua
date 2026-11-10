-- Cases of tools/koreader/check_rotation.lua. The screen needs its folders, and with an address outside a
-- private network it opens on the "no local network" message, without starting a session on the Wi-Fi of
-- the computer. The rotation is handled the same way in every state of the screen.
require("book_drop/lan").install("book_drop")
require("book_drop/awake").install("book_drop")

local out_dir = assert(os.getenv("OUTPUT_DIR"))
os.execute(string.format("mkdir -p '%s/books' '%s/shots'", out_dir, out_dir))

return {
    ["book_drop/ui/screen"] = function()
        return { books_dir = out_dir .. "/books", screenshot_dir = out_dir .. "/shots", local_ip = "127.0.0.1" }
    end,
}
