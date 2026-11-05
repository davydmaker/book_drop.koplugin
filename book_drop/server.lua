local socket = require("socket")

local Access = require("book_drop/access")

local Server = {}
Server.__index = Server

local CHUNK = 65536
-- How long one tick may work on transfers before giving the interface its turn again.
local TICK_BUDGET = 0.03
local MAX_ACCEPTS = 4
local MAX_PASSES = 256
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
    conn.body = nil
    if result.path then
        -- The length comes from the open file, not from a listing that may be a few seconds old, and no more
        -- than that is sent, so the head always tells the truth about the body.
        local file = io.open(result.path, "rb")
        local size = file and file:seek("end")
        if not size or not file:seek("set", 0) then
            if file then
                file:close()
            end
            result = { status = 500, body = "", content_type = "text/plain" }
        else
            conn.file, conn.file_left = file, size
            conn.outgoing = Access.response_head(result, size)
        end
    end
    if not conn.file then
        conn.outgoing = Access.response_head(result, #result.body)
        -- Sent after the head instead of joined to it, which would copy a cover of megabytes once more.
        conn.body = result.body
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
    return received ~= nil and #received > 0
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
        local chunk
        if conn.body then
            chunk, conn.body = conn.body, nil
        elseif conn.file and conn.file_left > 0 then
            chunk = conn.file:read(math.min(CHUNK, conn.file_left))
            conn.file_left = conn.file_left - (chunk and #chunk or 0)
        end
        if not chunk then
            conn.done = true
            return false
        end
        conn.outgoing, conn.sent = chunk, 0
        if chunk == "" then
            return true
        end
    end
    local before = conn.sent
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
    return conn.sent > before
end

-- The device the person is using has its own places, so other addresses on the network can never take them,
-- however many they are. The others share what is left.
function Server:has_room(ip)
    local preferred = self.access:preferred_ip()
    local from_ip, others = 0, 0
    for _, conn in ipairs(self.connections) do
        if conn.ip == ip then
            from_ip = from_ip + 1
        end
        if conn.ip ~= preferred then
            others = others + 1
        end
    end
    if ip == preferred then
        return from_ip < MAX_CLIENT_CONNECTIONS
    end
    return from_ip < MAX_OTHER_CONNECTIONS and others < MAX_CONNECTIONS - MAX_CLIENT_CONNECTIONS
end

-- One step of a connection. Returns true when it moved, so it is worth trying again in this tick.
function Server:step(conn)
    if conn.done then
        return false
    end
    if conn.state == "reading" then
        return self:read_request(conn)
    elseif conn.state == "receiving" then
        return self:read_body(conn)
    end
    return self:send_response(conn)
end

-- Several at a time: a browser opens a few connections at once, for the covers of a page.
function Server:accept()
    for _ = 1, MAX_ACCEPTS do
        local client = self.listener:accept()
        if not client then
            return
        end
        client:settimeout(0)
        local ip = client:getpeername()
        -- A blocked address is dropped at once, so it cannot hold a place until its request times out.
        if not self.access:is_denied(ip) and self:has_room(ip) then
            table.insert(self.connections, { client = client, ip = ip, buffer = "", state = "reading", deadline = os.time() + REQUEST_TIMEOUT })
        else
            client:close()
        end
    end
end

-- Called repeatedly by the screen. Never waits, so the interface stays responsive during transfers.
function Server:tick()
    if not self.listener then
        return false
    end
    self:accept()
    local stop_at = socket.gettime() + TICK_BUDGET
    -- Rounds over every connection, so one big transfer does not hold back the others, until none of them
    -- moves or the time of this tick is over.
    for _ = 1, MAX_PASSES do
        local moved = false
        for _, conn in ipairs(self.connections) do
            -- An error in one request ends that connection, never the reader the person is using.
            local ok, progress = pcall(self.step, self, conn)
            if not ok then
                conn.done = true
            elseif progress then
                moved = true
            end
        end
        if not moved or socket.gettime() >= stop_at then
            break
        end
    end
    local now = os.time()
    for index = #self.connections, 1, -1 do
        local conn = self.connections[index]
        if conn.done or now > conn.deadline then
            self:close_connection(conn)
            table.remove(self.connections, index)
        end
    end
    return #self.connections > 0
end

return Server
