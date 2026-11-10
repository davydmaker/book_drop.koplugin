package.path = "./?.lua;" .. package.path
-- The server only needs these from LuaSocket, so the tests run without a network.
package.loaded.socket = package.loaded.socket or { gettime = os.clock }
local Access = require("book_drop/access")
local I18n = require("book_drop/i18n")
local Server = require("book_drop/http_server")

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

local TOKEN, HOST, PHONE = "abc123token", "192.168.0.5:8642", "192.168.0.20"

-- A connection that hands out what was queued in `input`, in pieces of the size asked for.
local function fake_client(ip, input)
    local client = { ip = ip, input = input or "", output = {}, closed = false }
    function client:getpeername() return self.ip end
    function client:settimeout() end
    function client:receive(size)
        if #self.input == 0 then
            if self.eof then return nil, "closed", "" end
            return nil, "timeout", ""
        end
        local chunk = self.input:sub(1, size)
        self.input = self.input:sub(size + 1)
        if #chunk == size then return chunk end
        return nil, "timeout", chunk
    end
    function client:send(data, first)
        first = first or 1
        local last = #data
        if self.send_limit then last = math.min(last, first + self.send_limit - 1) end
        self.output[#self.output + 1] = data:sub(first, last)
        return last
    end
    function client:close() self.closed = true end
    function client:response() return table.concat(self.output) end
    return client
end

local function fake_storage()
    local storage = { files = {}, committed = {}, discarded = 0, next_temp = 0 }
    function storage:begin()
        self.next_temp = self.next_temp + 1
        return os.tmpname()
    end
    function storage:commit(temp, name)
        local file = io.open(temp, "rb")
        self.committed[name] = file:read("*a")
        file:close()
        os.remove(temp)
        return true
    end
    function storage:discard(temp)
        self.discarded = self.discarded + 1
        os.remove(temp)
    end
    return storage
end

local function new_server(opts)
    opts = opts or {}
    local access = Access.new{
        token = TOKEN, host = HOST, strings = I18n.en,
        read_cover = function() end,
        list_shots = function() return opts.shots or {} end,
        list_books = function() return {} end,
        stat_file = function(path)
            for _, file in ipairs(opts.shots or {}) do
                if file.path == path then return file.size end
            end
        end,
        can_store = function() end,
        zip_status = function() end,
        on_new_client = function() end,
        is_busy = function() return opts.server and opts.server.uploading end,
    }
    local server = Server.new{ access = access, ip = "192.168.0.5", port = 8642, storage = fake_storage(), log = opts.log or function() end }
    opts.server = server
    local queue = {}
    server.listener = {
        accept = function() return table.remove(queue, 1) end,
        close = function() end,
    }
    server.queue = queue
    return server, access
end

local function approve(server, access)
    access:handle(string.format("GET /%s/ HTTP/1.1\r\nHost: %s\r\n\r\n", TOKEN, HOST), PHONE)
    access:approve(PHONE)
end

local function connect(server, client)
    table.insert(server.queue, client)
    return client
end

local function ticks(server, count)
    for _ = 1, count or 20 do server:tick() end
end

local function from(server, ip)
    local count = 0
    for _, conn in ipairs(server.connections) do
        if conn.ip == ip then count = count + 1 end
    end
    return count
end

test("other addresses cannot take the places of the device in use", function()
    local server, access = new_server()
    approve(server, access)
    for host = 101, 106 do
        for _ = 1, 3 do connect(server, fake_client("192.168.0." .. host)) end
    end
    ticks(server, 30)
    eq(#server.connections, 6)
    for _ = 1, 6 do connect(server, fake_client(PHONE)) end
    ticks(server, 10)
    eq(from(server, PHONE), 6)
    eq(#server.connections, 12)
end)

test("the device waiting for approval also has its places", function()
    local server, access = new_server()
    access:handle(string.format("GET /%s/ HTTP/1.1\r\nHost: %s\r\n\r\n", TOKEN, HOST), PHONE)
    for host = 101, 106 do
        for _ = 1, 2 do connect(server, fake_client("192.168.0." .. host)) end
    end
    ticks(server, 20)
    connect(server, fake_client(PHONE))
    ticks(server, 2)
    eq(from(server, PHONE), 1)
end)

test("a blocked address is dropped as soon as it connects", function()
    local server, access = new_server()
    approve(server, access)
    access.denied["192.168.0.99"] = true
    local client = connect(server, fake_client("192.168.0.99"))
    ticks(server, 2)
    eq(client.closed, true)
    eq(from(server, "192.168.0.99"), 0)
end)

local function request(path, method, extra)
    return string.format("%s /%s%s HTTP/1.1\r\nHost: %s\r\n%s\r\n", method or "GET", TOKEN, path, HOST, extra or "")
end

local function split(response)
    local head_end = response:find("\r\n\r\n", 1, true)
    return response:sub(1, head_end + 3), response:sub(head_end + 4)
end

test("a page is sent whole, with the length it announces", function()
    local server, access = new_server()
    approve(server, access)
    local client = connect(server, fake_client(PHONE, request("/")))
    client.send_limit = 100
    ticks(server, 200)
    local head, body = split(client:response())
    eq(head:find("HTTP/1.1 200 OK", 1, true), 1)
    eq(tonumber(head:match("Content%-Length: (%d+)")), #body)
    eq(body:find("<!doctype html>", 1, true), 1)
    eq(body:sub(-7), "</html>")
    eq(client.closed, true)
end)

local function temp_file(content)
    local path = os.tmpname()
    local file = io.open(path, "wb")
    file:write(content)
    file:close()
    return path
end

local function random_bytes(size)
    local parts = {}
    for index = 1, size / 256 do
        local block = {}
        for byte = 1, 256 do block[byte] = string.char((index * 31 + byte * 7) % 256) end
        parts[index] = table.concat(block)
    end
    return table.concat(parts)
end

test("a large download goes out in few ticks, and intact", function()
    local content = random_bytes(1024 * 1024)
    local path = temp_file(content)
    local opts = { shots = { { name = "big.png", path = path, size = #content } } }
    local server, access = new_server(opts)
    approve(server, access)
    connect(server, fake_client(PHONE, request("/shots")))
    ticks(server, 5)
    local client = connect(server, fake_client(PHONE, request("/shot/1")))
    ticks(server, 3)
    eq(client.closed, true)
    local head, body = split(client:response())
    eq(head:find("HTTP/1.1 200 OK", 1, true), 1)
    eq(#body, #content)
    eq(body == content, true)
    os.remove(path)
end)

test("two downloads at once both move in the same tick", function()
    local content = random_bytes(512 * 1024)
    local path = temp_file(content)
    local opts = { shots = { { name = "big.png", path = path, size = #content } } }
    local server, access = new_server(opts)
    approve(server, access)
    connect(server, fake_client(PHONE, request("/shots")))
    ticks(server, 5)
    local first = connect(server, fake_client(PHONE, request("/shot/1")))
    local second = connect(server, fake_client(PHONE, request("/shot/1")))
    first.send_limit, second.send_limit = 4096, 4096
    server:tick()
    eq(#first:response() > 0, true)
    eq(#second:response() > 0, true)
    os.remove(path)
end)

test("the length of a download comes from the file, not from an old listing", function()
    local content = random_bytes(4096)
    local path = temp_file(content)
    local opts = { shots = { { name = "shot.png", path = path, size = 10 } } }
    local server, access = new_server(opts)
    approve(server, access)
    connect(server, fake_client(PHONE, request("/shots")))
    ticks(server, 5)
    local client = connect(server, fake_client(PHONE, request("/shot/1")))
    ticks(server, 5)
    local head, body = split(client:response())
    eq(tonumber(head:match("Content%-Length: (%d+)")), #content)
    eq(body == content, true)
    os.remove(path)
end)

test("a file that cannot be opened is an error, not a broken download", function()
    local opts = { shots = { { name = "shot.png", path = "/nowhere/shot.png", size = 10 } } }
    local server, access = new_server(opts)
    approve(server, access)
    connect(server, fake_client(PHONE, request("/shots")))
    ticks(server, 5)
    local client = connect(server, fake_client(PHONE, request("/shot/1")))
    ticks(server, 5)
    eq(client:response():find("HTTP/1.1 500", 1, true), 1)
    eq(client:response():match("Content%-Length: (%d+)"), "0")
end)

test("an error in a request ends only that connection, and is logged", function()
    local logged = {}
    local opts = { log = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end }
    local server, access = new_server(opts)
    approve(server, access)
    access.list_shots = function() error("disk went away") end
    local broken = connect(server, fake_client(PHONE, request("/shots")))
    local fine = connect(server, fake_client(PHONE, request("/")))
    ticks(server, 5)
    eq(broken.closed, true)
    eq(#broken:response(), 0)
    eq(fine:response():find("HTTP/1.1 200 OK", 1, true), 1)
    eq(#logged, 1)
    eq(logged[1]:find("disk went away", 1, true) ~= nil, true)
    eq(logged[1]:find(TOKEN, 1, true), nil)
end)

-- os.time stands in for the clock, so a test can let seconds pass without waiting for them.
local function with_clock(fn)
    local real_time, now = os.time, os.time()
    os.time = function(date) return date and real_time(date) or now end
    local ok, err = pcall(fn, function(seconds) now = now + seconds end)
    os.time = real_time
    if not ok then error(err, 0) end
end

test("a connection that sends no request is closed after its deadline", function()
    with_clock(function(advance)
        local server = new_server()
        local silent = connect(server, fake_client(PHONE))
        for _ = 1, 9 do advance(1); server:tick() end
        eq(silent.closed, false)
        for _ = 1, 3 do advance(1); server:tick() end
        eq(silent.closed, true)
        eq(#server.connections, 0)
    end)
end)

test("time the interface spent busy does not count against the connections waiting", function()
    with_clock(function(advance)
        local server = new_server()
        local waiting = connect(server, fake_client(PHONE))
        server:tick()
        advance(15)
        server:tick()
        eq(waiting.closed, false)
    end)
end)

test("a request head larger than the limit is closed without reaching the access", function()
    local server, access = new_server()
    approve(server, access)
    local reached = 0
    local handle = access.handle
    access.handle = function(...) reached = reached + 1; return handle(...) end
    local client = connect(server, fake_client(PHONE, "GET /" .. TOKEN .. "/ HTTP/1.1\r\nX: " .. string.rep("a", Access.MAX_REQUEST_BYTES + 10)))
    ticks(server, 20)
    eq(client.closed, true)
    eq(#client:response(), 0)
    eq(reached, 0)
end)

local function upload(name, body, size)
    return request("/upload", "POST", string.format("X-File-Name: %s\r\nContent-Length: %d\r\n", name, size or #body)) .. body
end

test("an upload arrives whole and gets its name", function()
    local opts = {}
    local server, access = new_server(opts)
    approve(server, access)
    local content = random_bytes(300 * 1024)
    local client = connect(server, fake_client(PHONE, upload("livro.epub", content)))
    ticks(server, 10)
    eq(server.storage.committed["livro.epub"] == content, true)
    eq(client:response():find("HTTP/1.1 201 Created", 1, true), 1)
    eq(server.uploading, nil)
end)

test("a second upload while one is under way is refused", function()
    local opts = {}
    local server, access = new_server(opts)
    approve(server, access)
    local first = connect(server, fake_client(PHONE, upload("um.epub", "abc", 10)))
    ticks(server, 3)
    eq(server.uploading, true)
    local second = connect(server, fake_client(PHONE, upload("dois.epub", "abc")))
    ticks(server, 3)
    eq(second:response():find("HTTP/1.1 409 Conflict", 1, true), 1)
    eq(second:response():find(I18n.en.upload_busy, 1, true) ~= nil, true)
    first.eof = true
    ticks(server, 2)
    eq(server.uploading, nil)
end)

test("a cut upload leaves nothing behind", function()
    local opts = {}
    local server, access = new_server(opts)
    approve(server, access)
    local client = connect(server, fake_client(PHONE, upload("livro.epub", "metade", 100)))
    ticks(server, 3)
    client.eof = true
    ticks(server, 3)
    eq(server.storage.committed["livro.epub"], nil)
    eq(server.storage.discarded, 1)
    eq(server.uploading, nil)
    eq(#server.connections, 0)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
