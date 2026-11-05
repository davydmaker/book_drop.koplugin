-- Reads the cover image out of an EPUB, in memory. Everything inside the file is treated as untrusted.
local Cover = {}

local MAX_META_BYTES = 1024 * 1024
local MAX_IMAGE_BYTES = 5 * 1024 * 1024
local MAX_TAG_BYTES = 8192
local MAX_ENTRIES = 20000
local MAX_DIRECTORY_BYTES = 4 * 1024 * 1024
local END_RECORD_BYTES = 22
local MAX_ZIP_COMMENT_BYTES = 65535

local function attribute(tag, name)
    local value = tag:match("%s" .. name .. '%s*=%s*"([^"]*)"') or tag:match("%s" .. name .. "%s*=%s*'([^']*)'")
    return value
end

-- Walks the tags once. A pattern like "<item[^>]*>" would rescan the rest of the text from every
-- "<item", which a crafted file can turn into minutes with the reader frozen.
local function each_tag(text, callback)
    local position = 1
    while true do
        local open = text:find("<", position, true)
        if not open then
            return
        end
        local close = text:find(">", open, true)
        if not close then
            return
        end
        position = close + 1
        if close - open <= MAX_TAG_BYTES then
            local tag = text:sub(open, close)
            local name = tag:match("^<([%w:]+)%s")
            if name and callback(name:gsub("^.*:", ""):lower(), tag) then
                return
            end
        end
    end
end

function Cover.opf_path(container)
    local path
    each_tag(container, function(name, tag)
        if name == "rootfile" then
            path = attribute(tag, "full%-path")
            return true
        end
    end)
    return path
end

-- Same order as readers use: the EPUB 3 property, the EPUB 2 meta tag, then the name of an image item.
function Cover.find_href(opf)
    local cover_id, by_property
    local items = {}
    each_tag(opf, function(name, tag)
        if name == "meta" and not cover_id and attribute(tag, "name") == "cover" then
            cover_id = attribute(tag, "content")
        elseif name == "item" then
            items[#items + 1] = tag
        end
    end)
    local by_id, by_name
    for _, tag in ipairs(items) do
        local id, href = attribute(tag, "id"), attribute(tag, "href")
        local properties, media = attribute(tag, "properties"), attribute(tag, "media%-type")
        if href then
            if properties and (" " .. properties .. " "):find(" cover-image ", 1, true) then
                by_property = by_property or href
            end
            if cover_id and id == cover_id then
                by_id = by_id or href
            end
            if not by_name and media and media:find("^image/") and ((id or ""):lower():find("cover", 1, true) or href:lower():find("cover", 1, true)) then
                by_name = href
            end
        end
    end
    return by_property or by_id or by_name
end

-- The entry name inside the archive. It is only compared with the names listed there, never used as a path.
function Cover.resolve(opf_path, href)
    local folder = opf_path:match("^(.*/)") or ""
    local decoded = href:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    local parts = {}
    for part in (folder .. decoded):gmatch("[^/]+") do
        if part == ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

-- The content decides the type, not the name: an SVG or a page named .jpg is never served as an image.
function Cover.image_type(data)
    if data:sub(1, 3) == "\255\216\255" then
        return "image/jpeg"
    end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return "image/png"
    end
    if data:sub(1, 4) == "GIF8" then
        return "image/gif"
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return "image/webp"
    end
    return nil
end

local function little_endian(text, position, size)
    local value = 0
    for offset = size - 1, 0, -1 do
        value = value * 256 + text:byte(position + offset)
    end
    return value
end

-- The archive library accepts many formats and loads the whole list of entries before Lua can count them,
-- so the file is checked first: it must be a ZIP, with a directory of a reasonable size.
function Cover.is_acceptable_zip(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    local accepted = false
    if file:read(4) == "PK\3\4" then
        local size = file:seek("end")
        local tail_size = math.min(size, END_RECORD_BYTES + MAX_ZIP_COMMENT_BYTES)
        file:seek("set", size - tail_size)
        local tail = file:read(tail_size) or ""
        local record
        local search = 1
        while true do
            local found = tail:find("PK\5\6", search, true)
            if not found then
                break
            end
            record = found
            search = found + 1
        end
        if record and #tail - record + 1 >= END_RECORD_BYTES then
            local entries = little_endian(tail, record + 10, 2)
            local directory = little_endian(tail, record + 12, 4)
            accepted = entries > 0 and entries <= MAX_ENTRIES and directory <= MAX_DIRECTORY_BYTES
        end
    end
    file:close()
    return accepted
end

local function read_entry(reader, entries, name, limit)
    local entry = entries[name]
    if not entry then
        local wanted = name:lower()
        for key, candidate in pairs(entries) do
            if key:lower() == wanted then
                entry = candidate
                break
            end
        end
    end
    -- The size comes from the file, and it decides how much memory is allocated.
    if not entry or entry.mode ~= "file" or entry.size <= 0 or entry.size > limit then
        return nil
    end
    return reader:extractToMemory(entry.path)
end

-- Returns the image and its type, or nil when the book has no usable cover.
function Cover.read(path)
    if not path:lower():find("%.epub$") or not Cover.is_acceptable_zip(path) then
        return nil
    end
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(path) then
        return nil
    end
    local entries = {}
    for entry in reader:iterate() do
        entries[entry.path] = { path = entry.path, mode = entry.mode, size = tonumber(entry.size) }
    end
    local data, content_type
    local container = read_entry(reader, entries, "META-INF/container.xml", MAX_META_BYTES)
    local opf_path = container and Cover.opf_path(container)
    local opf = opf_path and read_entry(reader, entries, opf_path, MAX_META_BYTES)
    local href = opf and Cover.find_href(opf)
    if href then
        data = read_entry(reader, entries, Cover.resolve(opf_path, href), MAX_IMAGE_BYTES)
        content_type = data and Cover.image_type(data)
    end
    reader:close()
    if not content_type then
        return nil
    end
    return data, content_type
end

return Cover
