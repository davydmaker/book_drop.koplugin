local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Access = require("book_drop/access")
local Awake = require("book_drop/awake")
local Cover = require("book_drop/cover")
local I18n = require("book_drop/i18n")
local Lan = require("book_drop/lan")
local Portrait = require("book_drop/portrait")
local Refresh = require("book_drop/refresh")
local Server = require("book_drop/http_server")
local Sleep = require("book_drop/sleep")
local Storage = require("book_drop/storage")

local Device_screen = Device.screen

local PORT = 8642
local TICK_ACTIVE = 0.02
local TICK_IDLE = 0.25
local IDLE_LIMIT = 600
local BOOKS_CACHE_SECONDS = 5
-- Updates without a flash before a full refresh clears what e-ink leaves behind.
local PARTIAL_REFRESHES = 8
local SERIF = "noto/NotoSerif-Regular.ttf"
local SERIF_BOLD = "noto/NotoSerif-Bold.ttf"
-- Room for the headers of one entry in the zip, besides its name, which appears twice.
local ZIP_ENTRY_BYTES = 128
local ZIP_END_BYTES = 22

local Screen = InputContainer:extend{
    name = "book_drop_screen",
    covers_fullscreen = true,
    stop_events_propagation = true,
    screenshot_dir = nil,
    books_dir = nil,
    language = nil,
    -- Only for the checks in the emulator: the address the session would find on the Wi-Fi.
    local_ip = nil,
}

-- The temporary files of a session: the screenshots zip and a book cut in the middle. The firewall and the
-- awake mode have markers of their own, in lan.lua and awake.lua.
function Screen.marker_path()
    return DataStorage:getDataDir() .. "/cache/book_drop.active"
end

function Screen.write_marker()
    local marker = io.open(Screen.marker_path(), "w")
    if marker then
        marker:close()
    end
end

-- A crash or a forced quit skips onCloseWidget, which would leave the temporary files behind.
function Screen.recover(books_dir)
    if lfs.attributes(Screen.marker_path(), "mode") ~= "file" then
        return
    end
    os.remove(DataStorage:getDataDir() .. "/cache/book_drop.zip")
    Storage.new{ dir = books_dir, skip_dir = DataStorage:getDataDir() }:remove_leftovers()
    os.remove(Screen.marker_path())
end

function Screen:init()
    Sleep.watch(self)
    Portrait.open(self, self.setup)
end

function Screen:setup()
    self.dimen = Geom:new{ x = 0, y = 0, w = Device_screen:getWidth(), h = Device_screen:getHeight() }
    self.width, self.height = self.dimen.w, self.dimen.h
    self.text_width = self.width - 2 * Device_screen:scaleBySize(30)
    self.zip_dir = DataStorage:getDataDir() .. "/cache"
    self.zip_path = self.zip_dir .. "/book_drop.zip"
    self.storage = Storage.new{ dir = self.books_dir, skip_dir = DataStorage:getDataDir() }
    self.received = 0
    self.no_cover = {}
    self.refresh = Refresh.new(PARTIAL_REFRESHES)
    self.strings = I18n[self.language or I18n.language_from(G_reader_settings:readSetting("language"))]
    self.tick_callback = function() self:tick() end
    self.zip_callback = function() self:build_requested_zip() end
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
    -- A failure halfway would leave the port open and the device awake until KOReader starts again.
    local ok, err = xpcall(self.start_sharing, debug.traceback, self)
    if not ok then
        self:stop_sharing()
        error(err, 0)
    end
end

function Screen:list_shots()
    local files = {}
    local dir = self.screenshot_dir
    if dir and lfs.attributes(dir, "mode") == "directory" then
        pcall(function()
            for name in lfs.dir(dir) do
                local path = dir .. "/" .. name
                if name:sub(1, 1) ~= "." and Access.image_type(name) then
                    -- symlinkattributes, so a link never leads out of the folder.
                    local attributes = lfs.symlinkattributes(path)
                    if attributes and attributes.mode == "file" then
                        files[#files + 1] = { name = name, path = path, size = attributes.size, modified = attributes.modification }
                    end
                end
            end
        end)
    end
    table.sort(files, function(a, b) return a.name > b.name end)
    return files
end

-- The list comes from walking the folder, so it is kept for a moment, for the grid and the list views.
function Screen:list_books()
    local now = os.time()
    if not self.books_cache or now - self.books_cache_time > BOOKS_CACHE_SECONDS then
        self.books_cache, self.books_cache_time = self.storage:list_books(), now
        self.book_count = #self.books_cache
    end
    return self.books_cache
end

-- A book without a usable cover is remembered, by path and date, so scrolling back does not open it again.
-- Images are not kept: they would cost more memory than reading them again.
function Screen:read_cover(path)
    local key = string.format("%s/%s", path, tostring(lfs.attributes(path, "modification")))
    if self.no_cover[key] then
        return nil
    end
    local data, content_type = Cover.read(path)
    if not data then
        self.no_cover[key] = true
    end
    return data, content_type
end

-- symlinkattributes, so a listed file replaced by a link stops being served.
local function regular_file_size(path)
    local attributes = lfs.symlinkattributes(path)
    if attributes and attributes.mode == "file" then
        return attributes.size
    end
end

local function zip_signature(files)
    local parts = {}
    for index, file in ipairs(files) do
        parts[index] = string.format("%s/%d/%d", file.name, file.size, file.modified or 0)
    end
    return table.concat(parts, "\n")
end

-- files: { { name, path, size, modified } }. Returns { path, size }, or nil and "space". The zip is kept while
-- the screenshots stay the same, so asking again does not freeze the screen again.
function Screen:build_zip(files)
    local data_bytes, needed = 0, ZIP_END_BYTES
    for _, file in ipairs(files) do
        data_bytes = data_bytes + file.size
        needed = needed + file.size + ZIP_ENTRY_BYTES + 2 * #file.name
    end
    local signature = zip_signature(files)
    local size = lfs.attributes(self.zip_path, "size")
    if signature == self.zip_signature and size then
        return { path = self.zip_path, size = size }
    end
    self.zip_signature = nil
    os.remove(self.zip_path)
    -- The cache shares its partition with KOReader's settings, which must still have room to be saved.
    local available = util.diskUsage(self.zip_dir).available
    if available and available < needed + Storage.FREE_MARGIN_BYTES then
        return nil, "space"
    end
    local Archiver = require("ffi/archiver")
    local writer = Archiver.Writer:new{}
    if not writer:open(self.zip_path, "zip") then
        return nil
    end
    writer:setZipCompression("store")
    local failed = false
    -- addFileFromMemory writes the mode as decimal 644, which leaves extracted files unreadable.
    for _, file in ipairs(files) do
        writer:addPath(file.name, file.path)
        -- addPath returns false even when it works, since it ends on the end-of-list code, so its error is what tells.
        if writer.err then
            failed = true
            break
        end
    end
    writer:close()
    size = lfs.attributes(self.zip_path, "size")
    -- A failed final write is not reported, but a zip without compression is never smaller than its files.
    if failed or not size or size < data_bytes then
        os.remove(self.zip_path)
        return nil
    end
    self.zip_signature = signature
    return { path = self.zip_path, size = size }
end

-- Called by the access for each request of the zip. Building it copies every screenshot and freezes the
-- screen, so it never happens inside a request: the request schedules it, gets "pending", and the page asks
-- again until the zip is ready. A failed build is reported once, to the next request.
function Screen:zip_status()
    if self.zip_problem then
        local problem = self.zip_problem
        self.zip_problem = nil
        return nil, problem
    end
    local size = lfs.attributes(self.zip_path, "size")
    if size and self.zip_signature and self.zip_signature == zip_signature(self:list_shots()) then
        return { path = self.zip_path, size = size }
    end
    if not self.zip_building then
        self.zip_building = true
        Sleep.schedule(self, 0, self.zip_callback)
    end
    return nil, "pending"
end

-- The message reaches the screen before the work starts, so the frozen moment does not look like a crash.
function Screen:build_requested_zip()
    if not self.server then
        self.zip_building = false
        return
    end
    local activity = self.activity
    self.activity = self.strings.zip_preparing
    self:show_sharing()
    UIManager:forceRePaint()
    local zip, problem = self:build_zip(self:list_shots())
    if not zip then
        self.zip_problem = problem or "failed"
    end
    self.zip_building = false
    self.activity = activity
    self:show_sharing()
end

function Screen:start_sharing()
    local ip = self.local_ip or Lan.local_ip()
    if not ip or not Lan.is_private_ip(ip) then
        self:show_message(self.strings.no_network_title, self.strings.no_network_text)
        return
    end
    local token = Lan.random_token()
    if not token then
        self:show_message(self.strings.start_failed_title, self.strings.token_failed)
        return
    end
    self.ip = ip
    self.url = string.format("http://%s:%d/%s/", ip, PORT, token)
    self.access = Access.new{
        token = token,
        host = string.format("%s:%d", ip, PORT),
        strings = self.strings,
        read_cover = function(path) return self:read_cover(path) end,
        list_shots = function() return self:list_shots() end,
        list_books = function() return self:list_books() end,
        stat_file = regular_file_size,
        can_store = function(name, size) return self.storage:can_store(name, size) end,
        is_busy = function() return self.server ~= nil and self.server.uploading == true end,
        zip_status = function() return self:zip_status() end,
        on_new_client = function(client_ip) self:ask_permission(client_ip) end,
    }
    self.storage:remove_leftovers()
    local server = Server.new{
        access = self.access,
        ip = ip,
        port = PORT,
        name = "Book Drop",
        storage = self.storage,
        on_receiving = function(name) self:on_receiving(name) end,
        on_received = function(name) self:on_received(name) end,
    }
    local ok, err = server:start()
    if not ok then
        self:show_message(self.strings.start_failed_title, tostring(err))
        return
    end
    -- Only once the server is up, so a failed bind never leaves the port open.
    if not Lan.open_firewall(PORT) then
        server:stop()
        self:show_message(self.strings.start_failed_title, self.strings.firewall_failed)
        return
    end
    self.server = server
    self.firewall_open = true
    Screen.write_marker()
    self.state = "waiting"
    Awake.set(true)
    self:show_sharing()
    Sleep.schedule(self, TICK_IDLE, self.tick_callback)
end

-- The answer only counts while this session is running: the question may outlive it by sleep or the idle limit.
function Screen:ask_permission(client_ip)
    local access = self.access
    self.confirm = ConfirmBox:new{
        text = string.format(self.strings.allow_question, client_ip),
        ok_text = self.strings.allow_button,
        cancel_text = self.strings.deny_button,
        -- A tap outside the box would count as Deny, and a denied device stays out for the whole session.
        dismissable = false,
        ok_callback = function()
            self.confirm = nil
            if not self.server or self.access ~= access then
                return
            end
            access:approve(client_ip)
            self.state = "connected"
            self:show_sharing()
        end,
        cancel_callback = function()
            self.confirm = nil
            if not self.server or self.access ~= access then
                return
            end
            access:deny(client_ip)
        end,
    }
    Sleep.show(self, self.confirm)
end

function Screen:close_confirm()
    if self.confirm then
        UIManager:close(self.confirm)
        self.confirm = nil
    end
end

function Screen:on_receiving(name)
    self.activity = string.format(self.strings.receiving, name)
    self:show_sharing()
end

-- Counts the new book instead of walking the folder again: the list is read again only when the browser asks.
function Screen:on_received(name)
    self.received = self.received + 1
    self.books_cache = nil
    self.book_count = (self.book_count or 0) + 1
    self.activity = string.format(self.strings.last_received, name)
    self:show_sharing()
end

function Screen:tick()
    if not self.server then
        return
    end
    local busy = self.server:tick()
    if os.time() - self.server.last_activity > IDLE_LIMIT then
        self:stop_sharing(self.strings.idle_stop)
        return
    end
    Sleep.schedule(self, busy and TICK_ACTIVE or TICK_IDLE, self.tick_callback)
end

-- Safe to call more than once and from every way out: the button, the idle limit, sleep and closing.
function Screen:stop_sharing(message)
    Sleep.unschedule(self, self.tick_callback)
    Sleep.unschedule(self, self.zip_callback)
    self.zip_building, self.zip_problem, self.zip_signature = false, nil, nil
    self:close_confirm()
    if self.server then
        self.server:stop()
        self.server = nil
    end
    if self.firewall_open then
        self.firewall_open = nil
        if not Lan.close_firewall(PORT) then
            logger.warn("Book Drop: the port could not be closed; it is closed again when KOReader starts")
        end
    end
    Awake.set(false)
    if self.zip_path then
        os.remove(self.zip_path)
    end
    if self.storage then
        self.storage:remove_leftovers()
    end
    os.remove(Screen.marker_path())
    if message then
        self:show_message(self.strings.ended_title, message)
    end
end

function Screen:paragraph(text, face, size)
    return TextBoxWidget:new{ text = text, face = Font:getFace(face, size), width = self.text_width, alignment = "center" }
end

function Screen:button(text, callback)
    return Button:new{
        text = text,
        width = self.text_width,
        padding_v = Device_screen:scaleBySize(10),
        radius = Device_screen:scaleBySize(8),
        bordersize = Device_screen:scaleBySize(2),
        text_font_face = "cfont",
        text_font_size = 19,
        callback = callback,
    }
end

-- kind names the layout: a new one gets a full refresh, while a change of text in the same one, such as the
-- name of the book arriving, does not flash the whole screen.
function Screen:set_group(kind, group)
    if self[1] then
        self[1]:free()
    end
    self.content_height = group:getSize().h
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = self.width,
        height = self.height,
        CenterContainer:new{ dimen = Geom:new{ w = self.width, h = self.height }, group },
    }
    local mode = self.refresh:mode(kind)
    Sleep.dirty(self, function()
        return mode, self.dimen
    end)
end

function Screen:show_message(title, message)
    local gap = Device_screen:scaleBySize(16)
    self.state = "message"
    self:set_group("message", VerticalGroup:new{
        align = "center",
        self:paragraph(title, SERIF_BOLD, 28),
        VerticalSpan:new{ width = gap },
        self:paragraph(message, SERIF, 18),
        VerticalSpan:new{ width = gap * 2 },
        self:button(self.strings.close_button, function() UIManager:close(self) end),
    })
end

function Screen:counts_text()
    local s = self.strings
    local parts = { s.books(self.book_count or #self:list_books()), s.shots(#self:list_shots()) }
    if self.received > 0 then
        parts[#parts + 1] = s.received(self.received)
    end
    return table.concat(parts, " · ")
end

function Screen:show_sharing()
    if self.state == "connected" then
        self:show_connected()
    else
        self:show_waiting()
    end
end

function Screen:show_waiting()
    local s = self.strings
    local gap = Device_screen:scaleBySize(12)
    local qr_size = math.floor(math.min(self.width, self.height) * 0.62)
    self:set_group("waiting", VerticalGroup:new{
        align = "center",
        self:paragraph(s.title, SERIF_BOLD, 28),
        VerticalSpan:new{ width = gap },
        self:paragraph(s.scan_hint, SERIF, 17),
        VerticalSpan:new{ width = gap },
        QRWidget:new{ text = self.url, width = qr_size, height = qr_size },
        VerticalSpan:new{ width = gap },
        self:paragraph(self.url, SERIF, 14),
        VerticalSpan:new{ width = gap },
        self:paragraph(s.waiting, SERIF_BOLD, 17),
        self:paragraph(self:counts_text(), SERIF, 15),
        VerticalSpan:new{ width = gap },
        self:paragraph(s.privacy_note, SERIF, 14),
        VerticalSpan:new{ width = gap },
        self:button(s.stop_button, function() UIManager:close(self) end),
    })
end

-- The code is gone once a device is in, so this screen says who is connected and what is happening.
function Screen:show_connected()
    local s = self.strings
    local gap = Device_screen:scaleBySize(16)
    self:set_group("connected", VerticalGroup:new{
        align = "center",
        self:paragraph(s.title, SERIF, 20),
        VerticalSpan:new{ width = gap * 2 },
        self:paragraph(s.connected, SERIF_BOLD, 40),
        VerticalSpan:new{ width = gap },
        self:paragraph(string.format(s.connected_ip, self.access.client_ip), SERIF, 19),
        VerticalSpan:new{ width = gap * 2 },
        self:paragraph(self.activity or s.idle_activity, SERIF, 18),
        VerticalSpan:new{ width = gap },
        self:paragraph(self:counts_text(), SERIF, 16),
        VerticalSpan:new{ width = gap * 2 },
        self:paragraph(s.reopen_hint, SERIF, 14),
        self:paragraph(self.url, SERIF, 14),
        VerticalSpan:new{ width = gap },
        self:paragraph(s.privacy_note, SERIF, 14),
        VerticalSpan:new{ width = gap * 2 },
        self:button(s.stop_button, function() UIManager:close(self) end),
    })
end

function Screen:onSuspend()
    self:stop_sharing(self.strings.slept)
end

function Screen:onResume()
    self.refresh:reset()
end

Screen.onSetRotationMode = Portrait.ignore_rotation

function Screen:onBack()
    UIManager:close(self)
    return true
end

-- KOReader sends Close to every window before it quits (USB mode on a Kobo, closing the window on a computer).
function Screen:onClose(arg)
    if not (arg and arg.keep_screensaver) then
        UIManager:close(self)
    end
end

function Screen:onCloseWidget()
    self:stop_sharing()
    if self.received > 0 then
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end
    Portrait.close(self)
    UIManager:setDirty(nil, "full")
end

return Screen
