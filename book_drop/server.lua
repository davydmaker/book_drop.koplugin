local socket = require("socket")

local Access = require("book_drop/access")

local Server = {}
Server.__index = Server

local CHUNK = 16384
local MAX_CONNECTIONS = 12
local MAX_CLIENT_CONNECTIONS = 6
local MAX_OTHER_CONNECTIONS = 2
local REQUEST_TIMEOUT = 10
local TRANSFER_TIMEOUT = 30

-- opts: access, ip (the address to listen on), port, storage, on_receiving(name), on_received(name).
function Server.new(opts)
    return setmetatable({
        access = opts.access,
        ip = opts.ip,
        port = opts.port,
        storage = opts.storage,
        on_receiving = opts.on_receiving,
        on_received = opts.on_received,
        connections = {},
        last_activity = os.time(),
    }, Server)
end

function Server:start()
    local listener, err = socket.bind(self.ip, self.port)
    if not listener then
        return false, err
    end
    listener:settimeout(0)
    self.listener = listener
    return true
end

function Server:close_connection(conn)
    if conn.file then
        conn.file:close()
    end
    if conn.temp then
        self.storage:discard(conn.temp)
        self.uploading = nil
    end
    conn.client:close()
end

function Server:stop()
    for _, conn in ipairs(self.connections) do
        self:close_connection(conn)
    end
    self.connections = {}
    if self.listener then
        self.listener:close()
        self.listener = nil
    end
end

-- Only the approved device keeps the session alive, so a stranger or an unanswered request cannot stop the
-- idle limit, which is what lets the Kindle sleep again.
function Server:touch(conn)
    conn.deadline = os.time() + TRANSFER_TIMEOUT
    if conn.ip == self.access.client_ip then
        self.last_activity = os.time()
    end
end

function Server:reply(conn, result)
    if result.path then
        local file = io.open(result.path, "rb")
        if not file then
            result = { status = 500, body = "", content_type = "text/plain" }
        else
            conn.file = file
            conn.outgoing = Access.response_head(result, result.size)
        end
    end
    if not conn.file then
        conn.outgoing = Access.response_head(result, #result.body) .. result.body
    end
    conn.sent = 0
    conn.state = "sending"
    self:touch(conn)
end

function Server:abort_upload(conn, problem)
    conn.file:close()
    conn.file = nil
    self.storage:discard(conn.temp)
    conn.temp = nil
    self.uploading = nil
    self:reply(conn, self.access:upload_error(problem))
end

function Server:write_body(conn, data)
    if #data > conn.remaining then
        data = data:sub(1, conn.remaining)
    end
    if not conn.file:write(data) then
        self:abort_upload(conn, "write")
        return
    end
    conn.remaining = conn.remaining - #data
    self:touch(conn)
    if conn.remaining > 0 then
        return
    end
    local flushed = conn.file:close()
    conn.file = nil
    local temp, name = conn.temp, conn.upload_name
    conn.temp = nil
    self.uploading = nil
    if not flushed then
        self.storage:discard(temp)
        self:reply(conn, self.access:upload_error("write"))
        return
    end
    local ok, problem = self.storage:commit(temp, name)
    if not ok then
        self:reply(conn, self.access:upload_error(problem))
        return
    end
    if self.on_received then
        self.on_received(name)
    end
    self:reply(conn, self.access:upload_done())
end

function Server:begin_upload(conn, upload, body_start)
    if self.uploading then
        self:reply(conn, self.access:upload_error("busy"))
        return
    end
    local temp = self.storage:begin()
    local file = io.open(temp, "wb")
    if not file then
        self:reply(conn, self.access:upload_error("write"))
        return
    end
    self.uploading = true
    conn.file, conn.temp, conn.upload_name, conn.remaining = file, temp, upload.name, upload.size
    conn.state = "receiving"
    self:touch(conn)
    if self.on_receiving then
        self.on_receiving(upload.name)
    end
    if #body_start > 0 then
        self:write_body(conn, body_start)
    end
end

function Server:prepare_response(conn, head, body_start)
    local result = self.access:handle(head, conn.ip)
    if result.close_only then
        conn.done = true
        return
    end
    if result.upload then
        self:begin_upload(conn, result.upload, body_start)
        return
    end
    self:reply(conn, result)
end

function Server:read_request(conn)
    local data, err, partial = conn.client:receive(1024)
    local received = data or partial
    if received and #received > 0 then
        conn.buffer = conn.buffer .. received
    end
    local _, head_end = conn.buffer:find("\r?\n\r?\n")
    if head_end then
        self:prepare_response(conn, conn.buffer:sub(1, head_end), conn.buffer:sub(head_end + 1))
    elseif #conn.buffer > Access.MAX_REQUEST_BYTES then
        self:prepare_response(conn, conn.buffer, "")
    elseif err == "closed" then
        conn.done = true
    end
end

function Server:read_body(conn)
    local data, err, partial = conn.client:receive(math.min(CHUNK, conn.remaining))
    local received = data or partial
    if received and #received > 0 then
        self:write_body(conn, received)
    end
    if err == "closed" and conn.state == "receiving" then
        conn.done = true
    end
    return received and #received > 0
end

function Server:send_response(conn)
    if conn.sent >= #conn.outgoing then
        local chunk = conn.file and conn.file:read(CHUNK)
        if not chunk then
            conn.done = true
            return
        end
        conn.outgoing, conn.sent = chunk, 0
    end
    local last, err, partial = conn.client:send(conn.outgoing, conn.sent + 1)
    local position = last or partial or conn.sent
    -- Only real progress extends the deadline, so a stalled client cannot hold the connection.
    if position > conn.sent then
        conn.sent = position
        self:touch(conn)
    end
    if err == "closed" then
        conn.done = true
    end
end

function Server:has_room(ip)
    if #self.connections >= MAX_CONNECTIONS then
        return false
    end
    local from_ip = 0
    for _, conn in ipairs(self.connections) do
        if conn.ip == ip then
            from_ip = from_ip + 1
        end
    end
    return from_ip < (ip == self.access.client_ip and MAX_CLIENT_CONNECTIONS or MAX_OTHER_CONNECTIONS)
end

function Server:advance(conn)
    for _ = 1, 8 do
        if conn.done then break end
        if conn.state == "reading" then
            self:read_request(conn)
            if conn.state == "reading" then break end
        elseif conn.state == "receiving" then
            if not self:read_body(conn) then break end
        else
            self:send_response(conn)
        end
    end
end

-- Called repeatedly by the screen. Never waits, so the interface stays responsive during transfers.
function Server:tick()
    if not self.listener then
        return false
    end
    local client = self.listener:accept()
    if client then
        client:settimeout(0)
        local ip = client:getpeername()
        if self:has_room(ip) then
            table.insert(self.connections, { client = client, ip = ip, buffer = "", state = "reading", deadline = os.time() + REQUEST_TIMEOUT })
        else
            client:close()
        end
    end
    local now = os.time()
    for index = #self.connections, 1, -1 do
        local conn = self.connections[index]
        -- An error in one request ends that connection, never the reader the person is using.
        if not pcall(self.advance, self, conn) then
            conn.done = true
        end
        if conn.done or now > conn.deadline then
            self:close_connection(conn)
            table.remove(self.connections, index)
        end
    end
    return #self.connections > 0
end

return Server
