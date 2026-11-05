package.path = "./?.lua;" .. package.path
-- KOReader's lfs is LuaFileSystem, and the free space is the only thing taken from its util module.
package.loaded["libs/libkoreader-lfs"] = require("lfs")
local available = math.huge
package.loaded.util = { diskUsage = function() return { available = available } end }
local Storage = require("book_drop/storage")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAILED: " .. name .. "\n  " .. tostring(err))
    end
end
local function eq(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

local function write(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content or "x")
    file:close()
end

-- A books folder with what a real one has: subfolders, reading data, hidden items, links and other files.
local function library()
    local root = os.tmpname()
    os.remove(root)
    local dirs = { "", "/Serie", "/Serie/livro.sdr", "/.oculta", "/koreader", "/a/b/c/d/e/f/g" }
    for _, dir in ipairs(dirs) do os.execute(string.format("mkdir -p '%s%s'", root, dir)) end
    write(root .. "/zeta.epub", "12345")
    write(root .. "/Alfa.pdf", "123")
    write(root .. "/beta.EPUB", "1")
    write(root .. "/config.lua")
    write(root .. "/Serie/volume.cbz", "1234")
    write(root .. "/Serie/livro.sdr/metadata.epub")
    write(root .. "/.oculta/escondido.epub")
    write(root .. "/.escondido.epub")
    write(root .. "/koreader/dados.epub")
    write(root .. "/a/b/c/d/e/f/g/fundo.epub")
    write(root .. "/.book_drop-3.part")
    os.execute(string.format("ln -s /etc/hostname '%s/atalho.epub'", root))
    os.execute(string.format("ln -s '%s/Serie' '%s/pasta-link'", root, root))
    return root
end

local function labels(files)
    local out = {}
    for index, file in ipairs(files) do out[index] = file.label end
    return table.concat(out, ",")
end

test("lists only books, sorted without regard to case", function()
    local root = library()
    local storage = Storage.new{ dir = root, skip_dir = root .. "/koreader" }
    local files = storage:list_books()
    eq(labels(files), "Alfa.pdf,beta.EPUB,Serie/volume.cbz,zeta.epub")
    eq(files[4].size, 5)
    eq(files[3].path, root .. "/Serie/volume.cbz")
    os.execute(string.format("rm -rf '%s'", root))
end)

test("a missing folder lists nothing", function()
    eq(#Storage.new{ dir = "/nowhere/at/all" }:list_books(), 0)
    eq(Storage.new{ dir = "/nowhere/at/all" }:can_store("a.epub", 1), "folder")
end)

test("a name already taken or a file without room is refused", function()
    local root = library()
    local storage = Storage.new{ dir = root }
    eq(storage:can_store("zeta.epub", 10), "exists")
    eq(storage:can_store("atalho.epub", 10), "exists")
    eq(storage:can_store("novo.epub", 10), nil)
    available = Storage.FREE_MARGIN_BYTES + 5
    eq(storage:can_store("novo.epub", 10), "space")
    available = math.huge
    os.execute(string.format("rm -rf '%s'", root))
end)

test("a received file gets its name only if it is still free", function()
    local root = library()
    local storage = Storage.new{ dir = root }
    local temp = storage:begin()
    write(temp, "novo")
    eq(storage:commit(temp, "novo.epub"), true)
    eq(io.open(root .. "/novo.epub"):read("*a"), "novo")
    temp = storage:begin()
    write(temp, "outro")
    local ok, problem = storage:commit(temp, "zeta.epub")
    eq(ok, false); eq(problem, "exists")
    eq(io.open(root .. "/zeta.epub"):read("*a"), "12345")
    eq(io.open(temp), nil)
    os.execute(string.format("rm -rf '%s'", root))
end)

test("leftovers of a cut transfer go away, and nothing else", function()
    local root = library()
    local storage = Storage.new{ dir = root }
    storage:remove_leftovers()
    eq(io.open(root .. "/.book_drop-3.part"), nil)
    eq(io.open(root .. "/.escondido.epub") ~= nil, true)
    os.execute(string.format("rm -rf '%s'", root))
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
