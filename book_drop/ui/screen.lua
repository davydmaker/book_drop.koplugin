local bit = require("bit")
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
local PluginShare = require("pluginshare")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")

local Access = require("book_drop/access")
local Cover = require("book_drop/cover")
local I18n = require("book_drop/i18n")
local Server = require("book_drop/server")
local Storage = require("book_drop/storage")

local Device_screen = Device.screen

local PORT = 8642
local TICK_ACTIVE = 0.02
local TICK_IDLE = 0.25
local IDLE_LIMIT = 600
local BOOKS_CACHE_SECONDS = 5
local TOKEN_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
local TOKEN_LENGTH = 16
local SERIF = "noto/NotoSerif-Regular.ttf"
local SERIF_BOLD = "noto/NotoSerif-Bold.ttf"

local Screen = InputContainer:extend{
    name = "book_drop_screen",
    covers_fullscreen = true,
    stop_events_propagation = true,
    screenshot_dir = nil,
    books_dir = nil,
    language = nil,
    local_ip = nil,
    open_firewall = nil,
    close_firewall = nil,
}

local function random_token()
    local source = io.open("/dev/urandom", "rb")
    if not source then
        return nil
    end
    local bytes = source:read(TOKEN_LENGTH)
    source:close()
    if not bytes or #bytes < TOKEN_LENGTH then
        return nil
    end
    local out = {}
    for i = 1, TOKEN_LENGTH do
        local index = bytes:byte(i) % #TOKEN_ALPHABET + 1
        out[i] = TOKEN_ALPHABET:sub(index, index)
    end
    return table.concat(out)
end

-- Connecting a UDP socket picks the outgoing interface without sending any packet.
local function detect_local_ip()
    local udp = socket.udp()
    if not udp then
        return nil
    end
    udp:setpeername("10.255.255.255", 9)
    local ip = udp:getsockname()
    udp:close()
    return ip
end

local function firewall(action)
    if not Device:isKindle() then
        return
    end
    os.execute(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", action, PORT))
    os.execute(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", action, PORT))
end

function Screen.marker_path()
    return DataStorage:getDataDir() .. "/cache/book_drop.active"
end

function Screen.write_marker()
    local marker = io.open(Screen.marker_path(), "w")
    if marker then
        marker:close()
    end
end

-- A crash or a forced quit skips onCloseWidget, which would leave the port open and the Kindle awake.
function Screen.recover(books_dir)
    if lfs.attributes(Screen.marker_path(), "mode") ~= "file" then
        return
    end
    firewall("D")
    if Device:isKindle() and not PluginShare.keepalive then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    os.remove(DataStorage:getDataDir() .. "/cache/book_drop.zip")
    Storage.new{ dir = books_dir, skip_dir = DataStorage:getDataDir() }:remove_leftovers()
    os.remove(Screen.marker_path())
end

function Screen:init()
    -- The layout only fits portrait; odd rotation modes are landscape.
    local rotation = Device_screen:getRotationMode()
    if bit.band(rotation, 1) == 1 then
        self.restore_rotation = rotation
        Device_screen:setRotationMode(Device_screen.DEVICE_ROTATED_UPRIGHT)
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Device_screen:getWidth(), h = Device_screen:getHeight() }
    self.width, self.height = self.dimen.w, self.dimen.h
    self.text_width = self.width - 2 * Device_screen:scaleBySize(30)
    self.zip_path = DataStorage:getDataDir() .. "/cache/book_drop.zip"
    self.storage = Storage.new{ dir = self.books_dir, skip_dir = DataStorage:getDataDir() }
    self.received = 0
    self.strings = I18n[self.language or I18n.language_from(G_reader_settings:readSetting("language"))]
    self.tick_callback = function() self:tick() end
    self:start_sharing()
end

function Screen:list_shots()
    local files = {}
    local dir = self.screenshot_dir
    if lfs.attributes(dir, "mode") == "directory" then
        pcall(function()
            for name in lfs.dir(dir) do
                local path = dir .. "/" .. name
                -- symlinkattributes, so a link never leads out of the folder.
                if name:sub(1, 1) ~= "." and Access.image_type(name) and lfs.symlinkattributes(path, "mode") == "file" then
                    files[#files + 1] = { name = name, path = path, size = lfs.attributes(path, "size") }
                end
            end
        end)
    end
    table.sort(files, function(a, b) return a.name > b.name end)
    return files
end

-- The list comes from walking the folder, and each cover asks for it, so it is kept for a moment.
function Screen:list_books()
    local now = os.time()
    if not self.books_cache or now - self.books_cache_time > BOOKS_CACHE_SECONDS then
        self.books_cache, self.books_cache_time = self.storage:list_books(), now
    end
    return self.books_cache
end

function Screen:build_zip()
    local Archiver = require("ffi/archiver")
    local writer = Archiver.Writer:new{}
    os.remove(self.zip_path)
    if not writer:open(self.zip_path, "zip") then
        return nil
    end
    writer:setZipCompression("store")
    -- addFileFromMemory writes the mode as decimal 644, which leaves extracted files unreadable.
    for _, file in ipairs(self:list_shots()) do
        writer:addPath(file.name, file.path)
    end
    writer:close()
    return { path = self.zip_path, size = lfs.attributes(self.zip_path, "size") }
end

-- The screen stays on while this is open: if the Kindle slept, the Wi-Fi would drop in the middle of a transfer.
function Screen:keep_awake(on)
    if (self.awake or false) == on then
        return
    end
    self.awake = on
    if on then
        self.previous_pause = PluginShare.pause_auto_suspend
        PluginShare.pause_auto_suspend = true
    else
        PluginShare.pause_auto_suspend = self.previous_pause
    end
    if Device:isKindle() and not PluginShare.keepalive then
        os.execute(string.format("lipc-set-prop com.lab126.powerd preventScreenSaver %d", on and 1 or 0))
    end
end

function Screen:start_sharing()
    local ip = self.local_ip or detect_local_ip()
    if not ip or not Access.is_private_ip(ip) then
        self:show_message(self.strings.no_network_title, self.strings.no_network_text)
        return
    end
    local token = random_token()
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
        read_cover = Cover.read,
        list_shots = function() return self:list_shots() end,
        list_books = function() return self:list_books() end,
        can_store = function(name, size) return self.storage:can_store(name, size) end,
        build_zip = function() return self:build_zip() end,
        on_new_client = function(client_ip) self:ask_permission(client_ip) end,
    }
    self.storage:remove_leftovers()
    self.server = Server.new{
        access = self.access,
        ip = ip,
        port = PORT,
        storage = self.storage,
        on_receiving = function(name) self:on_receiving(name) end,
        on_received = function(name) self:on_received(name) end,
    }
    local close_firewall = self.close_firewall or function() firewall("D") end
    local open_firewall = self.open_firewall or function() firewall("A") end
    close_firewall()
    local ok, err = self.server:start()
    if not ok then
        self.server = nil
        self:show_message(self.strings.start_failed_title, tostring(err))
        return
    end
    Screen.write_marker()
    open_firewall()
    self.close_firewall_now = close_firewall
    self.state = "waiting"
    self:keep_awake(true)
    self:show_sharing()
    UIManager:scheduleIn(TICK_IDLE, self.tick_callback)
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
    UIManager:show(self.confirm)
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

function Screen:on_received(name)
    self.received = self.received + 1
    self.books_cache = nil
    self.activity = string.format(self.strings.last_received, name)
    self:show_sharing()
end

function Screen:tick()
    self.scheduled = false
    if not self.server then
        return
    end
    local busy = self.server:tick()
    if os.time() - self.server.last_activity > IDLE_LIMIT then
        self:stop_sharing(self.strings.idle_stop)
        return
    end
    UIManager:scheduleIn(busy and TICK_ACTIVE or TICK_IDLE, self.tick_callback)
end

function Screen:stop_sharing(message)
    UIManager:unschedule(self.tick_callback)
    self:close_confirm()
    if self.server then
        self.server:stop()
        self.server = nil
    end
    if self.close_firewall_now then
        self.close_firewall_now()
        self.close_firewall_now = nil
    end
    self:keep_awake(false)
    os.remove(self.zip_path)
    self.storage:remove_leftovers()
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

function Screen:set_group(group)
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
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)
end

function Screen:show_message(title, message)
    local gap = Device_screen:scaleBySize(16)
    self.state = "message"
    self:set_group(VerticalGroup:new{
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
    local parts = { s.books(#self:list_books()), s.shots(#self:list_shots()) }
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
    self:set_group(VerticalGroup:new{
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
    self:set_group(VerticalGroup:new{
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

function Screen:onSetRotationMode()
    return true
end

function Screen:onCloseWidget()
    self:stop_sharing()
    if self.received > 0 then
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end
    if self.restore_rotation then
        Device_screen:setRotationMode(self.restore_rotation)
    end
    UIManager:setDirty(nil, "full")
end

return Screen
