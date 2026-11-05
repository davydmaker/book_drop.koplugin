-- The books folder: what can be listed and how a received file gets there.
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Access = require("book_drop/access")

local Storage = {}
Storage.__index = Storage

local MAX_DEPTH = 6
local MAX_BOOKS = 5000
-- Keeps room for the reading data KOReader writes next to the books.
local FREE_MARGIN_BYTES = 50 * 1024 * 1024
local TEMP_PREFIX = ".book_drop-"
local TEMP_SUFFIX = ".part"

-- opts: dir (the books folder), skip_dir (KOReader's data folder, in case dir contains it).
function Storage.new(opts)
    return setmetatable({ dir = opts.dir, skip_dir = opts.skip_dir, next_temp = 0 }, Storage)
end

function Storage:has_dir()
    return self.dir ~= nil and lfs.attributes(self.dir, "mode") == "directory"
end

function Storage:scan(dir, prefix, depth, files)
    for name in lfs.dir(dir) do
        if name:sub(1, 1) ~= "." and #files < MAX_BOOKS then
            local path = dir .. "/" .. name
            -- symlinkattributes, so a link never leads out of the folder.
            local mode = lfs.symlinkattributes(path, "mode")
            if mode == "file" and Access.is_book(name) then
                files[#files + 1] = { name = name, label = prefix .. name, path = path, size = lfs.attributes(path, "size") }
            elseif mode == "directory" and depth < MAX_DEPTH and not name:find("%.sdr$") and path ~= self.skip_dir then
                self:scan(path, prefix .. name .. "/", depth + 1, files)
            end
        end
    end
end

function Storage:list_books()
    local files = {}
    if self:has_dir() then
        -- lfs.dir raises on an I/O error, and nothing up the stack should have to care.
        pcall(self.scan, self, self.dir, "", 1, files)
    end
    table.sort(files, function(a, b) return a.label:lower() < b.label:lower() end)
    return files
end

function Storage:can_store(name, size)
    if not self:has_dir() then
        return "folder"
    end
    if lfs.symlinkattributes(self.dir .. "/" .. name, "mode") then
        return "exists"
    end
    local available = util.diskUsage(self.dir).available
    if available and available < size + FREE_MARGIN_BYTES then
        return "space"
    end
    return nil
end

function Storage:begin()
    self.next_temp = self.next_temp + 1
    return string.format("%s/%s%d%s", self.dir, TEMP_PREFIX, self.next_temp, TEMP_SUFFIX)
end

-- Checks again, since the name may have appeared while the file was being received.
function Storage:commit(temp, name)
    local target = self.dir .. "/" .. name
    if lfs.symlinkattributes(target, "mode") then
        os.remove(temp)
        return false, "exists"
    end
    if not os.rename(temp, target) then
        os.remove(temp)
        return false, "write"
    end
    return true
end

function Storage:discard(temp)
    os.remove(temp)
end

-- Temporary files left by a shutdown in the middle of a transfer.
function Storage:remove_leftovers()
    if not self:has_dir() then
        return
    end
    pcall(function()
        for name in lfs.dir(self.dir) do
            if name:sub(1, #TEMP_PREFIX) == TEMP_PREFIX and name:sub(-#TEMP_SUFFIX) == TEMP_SUFFIX then
                os.remove(self.dir .. "/" .. name)
            end
        end
    end)
end

return Storage
