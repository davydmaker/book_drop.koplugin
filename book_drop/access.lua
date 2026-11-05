-- Decides what each request gets. It never touches the network or the disk, so every rule can be tested alone.
local Access = {}
Access.__index = Access

Access.MAX_BAD_REQUESTS = 20
Access.MAX_REQUEST_BYTES = 8192
Access.MAX_UPLOAD_BYTES = 500 * 1024 * 1024

local IMAGE_TYPES = { png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg" }
local BOOK_EXTENSIONS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true, prc = true,
    fb2 = true, djvu = true, cbz = true, txt = true, rtf = true,
}
local MAX_NAME_BYTES = 200

local UPLOAD_ERRORS = {
    exists = { 409, "upload_exists" },
    space = { 507, "upload_space" },
    folder = { 500, "upload_folder" },
    write = { 500, "upload_write" },
    busy = { 409, "upload_busy" },
}

local PLACEHOLDER_COVER = table.concat{
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 300">',
    '<rect width="200" height="300" fill="#e8e8e8"/><rect x="14" y="0" width="6" height="300" fill="#bbb"/>',
    '<rect x="50" y="90" width="110" height="8" fill="#999"/><rect x="50" y="110" width="80" height="8" fill="#999"/>',
    "</svg>",
}

local function escape_html(text)
    return (tostring(text):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

function Access.is_private_ip(ip)
    local a, b = tostring(ip):match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if not a then
        return false
    end
    return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
end

local function extension_of(name)
    local extension = tostring(name):match("%.([%w]+)$")
    return extension and extension:lower()
end

function Access.image_type(name)
    return IMAGE_TYPES[extension_of(name)]
end

function Access.is_book(name)
    return BOOK_EXTENSIONS[extension_of(name)] == true
end

-- Strict UTF-8, without overlong forms or surrogates, and without the controls that reverse how a name is shown.
local function is_valid_utf8(text)
    local index, size = 1, #text
    while index <= size do
        local byte = text:byte(index)
        local length, low, high = nil, 0x80, 0xBF
        if byte < 0x80 then
            length = 1
        elseif byte >= 0xC2 and byte <= 0xDF then
            length = 2
        elseif byte >= 0xE0 and byte <= 0xEF then
            length = 3
            if byte == 0xE0 then low = 0xA0 elseif byte == 0xED then high = 0x9F end
        elseif byte >= 0xF0 and byte <= 0xF4 then
            length = 4
            if byte == 0xF0 then low = 0x90 elseif byte == 0xF4 then high = 0x8F end
        end
        if not length or index + length - 1 > size then
            return false
        end
        for next_index = index + 1, index + length - 1 do
            local following = text:byte(next_index)
            if following < low or following > high then
                return false
            end
            low, high = 0x80, 0xBF
        end
        if byte == 0xE2 then
            local second, third = text:byte(index + 1), text:byte(index + 2)
            if (second == 0x80 and third >= 0xAA and third <= 0xAE) or (second == 0x81 and third >= 0xA6 and third <= 0xA9) then
                return false
            end
        end
        index = index + length
    end
    return true
end

-- The name comes from the other device, so nothing in it may choose a folder or a hidden file.
function Access.clean_upload_name(raw)
    local name = tostring(raw):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    if name:find("%c") or name:find("[/\\]") or #name > MAX_NAME_BYTES or not is_valid_utf8(name) then
        return nil
    end
    name = name:gsub('[:*?"<>|]', "_"):gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if name == "" or not name:find("[^%.]%.[%w]+$") then
        return nil
    end
    return name
end

function Access:format_size(bytes)
    if bytes >= 1024 * 1024 then
        return (string.format("%.1f MB", bytes / (1024 * 1024)):gsub("%.", self.strings.decimal))
    end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024)))
end

-- opts: token, host (the "ip:port" this server answers to), strings (a table from i18n.lua), list_shots()
-- and list_books() returning { { name, path, size } }, build_zip() returning { path, size } or nil and "space",
-- can_store(name, size) returning nil or a key of UPLOAD_ERRORS, read_cover(path) returning the image and
-- its type, or nil, stat_file(path) returning the size of a regular file (nil for a link or anything else),
-- on_new_client(ip).
function Access.new(opts)
    return setmetatable({
        token = opts.token,
        host = opts.host,
        strings = opts.strings,
        read_cover = opts.read_cover,
        list_shots = opts.list_shots,
        list_books = opts.list_books,
        stat_file = opts.stat_file,
        build_zip = opts.build_zip,
        can_store = opts.can_store,
        on_new_client = opts.on_new_client,
        client_ip = nil,
        pending_ip = nil,
        denied = {},
        strikes = {},
        ids = { shot = { by_id = {}, by_path = {}, last = 0 }, book = { by_id = {}, by_path = {}, last = 0 } },
    }, Access)
end

function Access:approve(ip)
    if self.pending_ip == ip then
        self.client_ip = ip
        self.pending_ip = nil
    end
end

function Access:deny(ip)
    self.denied[ip] = true
    if self.pending_ip == ip then
        self.pending_ip = nil
    end
end

function Access:is_denied(ip)
    return self.denied[ip] == true
end

-- The device that is approved, or waiting for approval: the one the person is using.
function Access:preferred_ip()
    return self.client_ip or self.pending_ip
end

local function response(status, body, extra)
    local result = { status = status, body = body, content_type = "text/html; charset=utf-8" }
    for key, value in pairs(extra or {}) do
        result[key] = value
    end
    return result
end

local function text_response(status, body)
    return response(status, body, { content_type = "text/plain; charset=utf-8" })
end

function Access:upload_error(key)
    local entry = UPLOAD_ERRORS[key] or UPLOAD_ERRORS.write
    return text_response(entry[1], self.strings[entry[2]])
end

function Access:upload_done()
    return text_response(201, "ok")
end

-- Strikes are per address, so someone else on the network can only lock themselves out. The approved
-- device is never locked out: its browser asks for things like /favicon.ico by itself.
function Access:reject(ip)
    if ip ~= self.client_ip then
        self.strikes[ip] = (self.strikes[ip] or 0) + 1
        if self.strikes[ip] >= Access.MAX_BAD_REQUESTS then
            self.denied[ip] = true
        end
    end
    -- The same answer for everything unknown, so nothing reveals what exists.
    return text_response(404, self.strings.not_found)
end

local STYLE = table.concat{
    "body{font-family:Georgia,serif;margin:0 auto;max-width:960px;padding:16px;color:#111;background:#fff}",
    "h1{font-size:26px;margin:8px 0}p{line-height:1.4}",
    "nav{display:flex;gap:8px;margin:12px 0 20px}",
    "nav a{flex:1;text-align:center;border:2px solid #111;padding:10px 4px;text-decoration:none;color:#111}",
    "nav a.on{background:#111;color:#fff;font-weight:bold}",
    ".all,button{display:block;width:100%;box-sizing:border-box;text-align:center;background:#111;color:#fff;border:0;padding:14px;margin:16px 0;text-decoration:none;font:bold 16px Georgia,serif}",
    "button:disabled{background:#777}",
    "input{display:block;width:100%;box-sizing:border-box;margin:16px 0;font-size:16px}",
    ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}",
    ".item{border:2px solid #111;padding:6px;text-decoration:none;color:#111;font-size:13px;overflow-wrap:anywhere}",
    ".item img{display:block;width:100%;height:auto;margin-bottom:6px;background:#eee}",
    ".item small,.row small{display:block;color:#555;margin-top:4px}",
    ".row{display:flex;align-items:center;gap:12px;border-bottom:1px solid #999;padding:8px 2px;text-decoration:none;color:#111;overflow-wrap:anywhere}",
    ".row img{width:48px;height:72px;object-fit:cover;background:#eee;flex:none}",
    ".views{display:flex;gap:16px;margin:12px 0}.views b,.views a{color:#111}",
    "#progress p{margin:8px 0;overflow-wrap:anywhere}",
}

function Access:page(title, body, extra)
    extra = extra or {}
    return table.concat{
        string.format('<!doctype html><html lang="%s"><head><meta charset="utf-8">', self.strings.html_lang),
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        extra.refresh and '<meta http-equiv="refresh" content="2">' or "",
        '<link rel="icon" href="data:,">',
        "<title>", escape_html(title), "</title><style>", STYLE, "</style></head><body>",
        body,
        extra.script and string.format('<script src="%s"></script>', extra.script) or "",
        "</body></html>",
    }
end

function Access:nav(current)
    local s = self.strings
    local items = { { "", s.nav_send }, { "books", s.nav_books }, { "shots", s.nav_shots } }
    local out = { "<h1>", escape_html(s.title), "</h1><nav>" }
    for _, item in ipairs(items) do
        out[#out + 1] = string.format('<a href="/%s/%s"%s>%s</a>', self.token, item[1], item[1] == current and ' class="on"' or "", escape_html(item[2]))
    end
    out[#out + 1] = "</nav>"
    return table.concat(out)
end

function Access:assign_ids(section, files)
    local ids = self.ids[section]
    for _, file in ipairs(files) do
        if not ids.by_path[file.path] then
            ids.last = ids.last + 1
            ids.by_path[file.path] = ids.last
            ids.by_id[ids.last] = { path = file.path, name = file.name }
        end
        file.id = ids.by_path[file.path]
    end
end

-- Numbers stay the same during a session, so a file received meanwhile cannot turn a link into another file.
-- Only a path the server listed can be reached, and only while it is still a regular file: checking that one
-- path is enough, so a cover or a download never has to walk the whole folder again.
function Access:find_file(section, id)
    local entry = self.ids[section].by_id[tonumber(id)]
    if not entry then
        return nil
    end
    local size = self.stat_file(entry.path)
    if not size then
        return nil
    end
    return { name = entry.name, path = entry.path, size = size }
end

function Access:send_page()
    local s = self.strings
    local body = {
        self:nav(""),
        "<p>", escape_html(s.send_intro), "</p>",
        "<noscript><p>", escape_html(s.send_noscript), "</p></noscript>",
        '<input id="files" type="file" multiple accept=".epub,.pdf,.mobi,.azw,.azw3,.prc,.fb2,.djvu,.cbz,.txt,.rtf">',
        '<button id="send" type="button">', escape_html(s.send_button), "</button>",
        '<div id="progress"></div>',
    }
    return response(200, self:page(s.send_title, table.concat(body), { script = string.format("/%s/upload.js", self.token) }))
end

local function book_title(file)
    return (file.label or file.name):gsub("%.[%w]+$", "")
end

function Access:book_details(file)
    return string.format("%s · %s", extension_of(file.name):upper(), self:format_size(file.size))
end

function Access:books_page(view)
    local s = self.strings
    local files = self.list_books()
    self:assign_ids("book", files)
    local body = { self:nav("books") }
    if #files == 0 then
        body[#body + 1] = "<p>" .. escape_html(s.no_books) .. "</p>"
        return response(200, self:page(s.books_title, table.concat(body)))
    end
    body[#body + 1] = "<p>" .. escape_html(string.format(s.books_hint, s.books(#files))) .. "</p>"
    if view == "list" then
        body[#body + 1] = string.format('<div class="views"><a href="/%s/books">%s</a><b>%s</b></div>', self.token, escape_html(s.view_grid), escape_html(s.view_list))
        for _, file in ipairs(files) do
            body[#body + 1] = string.format('<a class="row" href="/%s/book/%d"><img src="/%s/cover/%d" alt="" loading="lazy"><span>%s<small>%s</small></span></a>',
                self.token, file.id, self.token, file.id, escape_html(book_title(file)), self:book_details(file))
        end
    else
        body[#body + 1] = string.format('<div class="views"><b>%s</b><a href="/%s/books/list">%s</a></div><div class="grid">', escape_html(s.view_grid), self.token, escape_html(s.view_list))
        for _, file in ipairs(files) do
            body[#body + 1] = string.format('<a class="item" href="/%s/book/%d"><img src="/%s/cover/%d" alt="" loading="lazy">%s<small>%s</small></a>',
                self.token, file.id, self.token, file.id, escape_html(book_title(file)), self:book_details(file))
        end
        body[#body + 1] = "</div>"
    end
    return response(200, self:page(s.books_title, table.concat(body)))
end

function Access:cover_response(file)
    local data, content_type = self.read_cover(file.path)
    if data then
        return { status = 200, body = data, content_type = content_type, cacheable = true }
    end
    return { status = 200, body = PLACEHOLDER_COVER, content_type = "image/svg+xml", cacheable = true }
end

function Access:shots_page()
    local s = self.strings
    local files = self.list_shots()
    self:assign_ids("shot", files)
    local items = {}
    for index, file in ipairs(files) do
        local url = string.format("/%s/shot/%d", self.token, file.id)
        items[index] = string.format('<a class="item" href="%s" download="%s"><img src="%s" alt="" loading="lazy">%s</a>',
            url, escape_html(file.name), url, escape_html(file.name))
    end
    local body = { self:nav("shots") }
    if #files == 0 then
        body[#body + 1] = "<p>" .. escape_html(s.no_shots) .. "</p>"
    else
        body[#body + 1] = "<p>" .. escape_html(string.format(s.shots_hint, s.images(#files))) .. "</p>"
        body[#body + 1] = string.format('<a class="all" href="/%s/all.zip">%s</a>', self.token, escape_html(s.download_all))
        body[#body + 1] = '<div class="grid">' .. table.concat(items) .. "</div>"
    end
    return response(200, self:page(s.shots_title, table.concat(body)))
end

local UPLOAD_SCRIPT = [[
(function () {
  var TEXT = {checking: %CHECKING%, lost: %LOST%, done: %DONE%};
  var base = location.pathname.match(/^\/[^\/]+\//)[0];
  var input = document.getElementById("files");
  var button = document.getElementById("send");
  var progress = document.getElementById("progress");
  function send(files, index) {
    if (index >= files.length) {
      button.disabled = false;
      input.value = "";
      return;
    }
    var file = files[index];
    var row = document.createElement("p");
    row.textContent = file.name + ": " + TEXT.checking;
    progress.appendChild(row);
    function finish(message) {
      row.textContent = file.name + ": " + message;
      send(files, index + 1);
    }
    var check = new XMLHttpRequest();
    check.open("GET", base + "can-upload?name=" + encodeURIComponent(file.name) + "&size=" + file.size);
    check.onerror = function () { finish(TEXT.lost); };
    check.onload = function () {
      if (check.status !== 200) { finish(check.responseText); return; }
      var upload = new XMLHttpRequest();
      upload.open("POST", base + "upload");
      upload.setRequestHeader("X-File-Name", encodeURIComponent(file.name));
      upload.upload.onprogress = function (event) {
        if (event.lengthComputable) {
          row.textContent = file.name + ": " + Math.floor(event.loaded * 100 / event.total) + "%";
        }
      };
      upload.onerror = function () { finish(TEXT.lost); };
      upload.onload = function () {
        finish(upload.status === 201 ? TEXT.done : upload.responseText);
      };
      upload.send(file);
    };
    check.send();
  }
  button.onclick = function () {
    if (!input.files.length) { return; }
    button.disabled = true;
    progress.textContent = "";
    send(Array.prototype.slice.call(input.files), 0);
  };
})();
]]

local function js_string(text)
    return '"' .. text:gsub('[\\"<>&]', function(char)
        return string.format("\\x%02x", char:byte())
    end) .. '"'
end

function Access:upload_script()
    local s = self.strings
    local values = { ["%CHECKING%"] = js_string(s.upload_checking), ["%LOST%"] = js_string(s.upload_lost), ["%DONE%"] = js_string(s.upload_done) }
    return (UPLOAD_SCRIPT:gsub("%%%u+%%", values))
end

function Access:check_upload(raw_name, size_text)
    local s = self.strings
    local size = size_text and size_text:match("^%d+$") and tonumber(size_text)
    if not size or size == 0 then
        return text_response(400, s.upload_empty)
    end
    if size > Access.MAX_UPLOAD_BYTES then
        return text_response(413, s.upload_too_big)
    end
    local name = raw_name and Access.clean_upload_name(raw_name)
    if not name then
        return text_response(400, s.upload_bad_name)
    end
    if not Access.is_book(name) then
        return text_response(415, s.upload_bad_format)
    end
    local problem = self.can_store(name, size)
    if problem then
        return self:upload_error(problem)
    end
    return nil, name, size
end

local function read_headers(request)
    local headers, repeated = {}, false
    for line in request:gmatch("\n([^\r\n]+)") do
        local key, value = line:match("^([%w%-]+):[ \t]*(.-)[ \t]*$")
        if key then
            key = key:lower()
            if headers[key] then
                repeated = true
            end
            headers[key] = value
        end
    end
    return headers, repeated
end

function Access:handle_upload(request, rest, ip)
    if rest ~= "/upload" then
        return self:reject(ip)
    end
    local headers, repeated = read_headers(request)
    -- Only the page served here sends this header, and another site's page cannot send it without permission.
    if repeated or headers["transfer-encoding"] or not headers["x-file-name"] then
        return self:reject(ip)
    end
    if headers.origin and headers.origin ~= "http://" .. self.host then
        return self:reject(ip)
    end
    local refusal, name, size = self:check_upload(headers["x-file-name"], headers["content-length"])
    if refusal then
        return refusal
    end
    return { upload = { name = name, size = size } }
end

-- request: the raw request head, without the body. ip: the address of the connection.
function Access:handle(request, ip)
    if self.denied[ip] then
        return { status = 503, body = "", content_type = "text/plain", close_only = true }
    end
    if #request > Access.MAX_REQUEST_BYTES or not Access.is_private_ip(ip) then
        return self:reject(ip)
    end
    local method, target = request:match("^(%u+) ([^%s]+) HTTP/1%.[01]\r?\n")
    if method ~= "GET" and method ~= "POST" then
        return self:reject(ip)
    end
    -- A request for another name is a page trying to reach this server through the browser.
    local host = request:match("\n[Hh][Oo][Ss][Tt]:[ \t]*([^\r\n]+)")
    if host ~= self.host then
        return self:reject(ip)
    end
    local token, rest = target:match("^/([%w]+)(/?.*)$")
    if token ~= self.token then
        return self:reject(ip)
    end
    if not self.client_ip then
        if method ~= "GET" then
            return self:reject(ip)
        end
        if not self.pending_ip then
            self.pending_ip = ip
            self.on_new_client(ip)
        end
        if self.pending_ip ~= ip then
            return self:reject(ip)
        end
        local s = self.strings
        return response(200, self:page(s.waiting_title, string.format("<h1>%s</h1><p>%s</p>", escape_html(s.confirm_heading), escape_html(s.confirm_text)), { refresh = true }))
    end
    if ip ~= self.client_ip then
        return self:reject(ip)
    end
    if method == "POST" then
        return self:handle_upload(request, rest, ip)
    end
    if rest == "" or rest == "/" then
        return self:send_page()
    end
    if rest == "/books" then
        return self:books_page("grid")
    end
    if rest == "/books/list" then
        return self:books_page("list")
    end
    if rest == "/shots" then
        return self:shots_page()
    end
    if rest == "/upload.js" then
        return response(200, self:upload_script(), { content_type = "text/javascript; charset=utf-8" })
    end
    if rest == "/all.zip" then
        local zip, problem = self.build_zip()
        if not zip then
            if problem == "space" then
                return text_response(507, self.strings.zip_space)
            end
            return text_response(500, self.strings.zip_failed)
        end
        return { status = 200, path = zip.path, size = zip.size, content_type = "application/zip", download_name = self.strings.zip_name }
    end
    local raw_name, size_text = rest:match("^/can%-upload%?name=([^&]*)&size=(%d+)$")
    if raw_name then
        return self:check_upload(raw_name, size_text) or text_response(200, "ok")
    end
    local shot_id = rest:match("^/shot/(%d+)$")
    if shot_id then
        local file = self:find_file("shot", shot_id)
        if not file or not Access.image_type(file.name) then
            return self:reject(ip)
        end
        return { status = 200, path = file.path, size = file.size, content_type = Access.image_type(file.name), download_name = file.name }
    end
    local cover_id = rest:match("^/cover/(%d+)$")
    if cover_id then
        local file = self:find_file("book", cover_id)
        if not file or not Access.is_book(file.name) then
            return self:reject(ip)
        end
        return self:cover_response(file)
    end
    local book_id = rest:match("^/book/(%d+)$")
    if book_id then
        local file = self:find_file("book", book_id)
        if not file or not Access.is_book(file.name) then
            return self:reject(ip)
        end
        return { status = 200, path = file.path, size = file.size, content_type = "application/octet-stream", download_name = file.name, attachment = true }
    end
    return self:reject(ip)
end

local STATUS_TEXT = {
    [200] = "OK", [201] = "Created", [400] = "Bad Request", [404] = "Not Found", [409] = "Conflict", [413] = "Content Too Large",
    [415] = "Unsupported Media Type", [500] = "Internal Server Error", [503] = "Service Unavailable", [507] = "Insufficient Storage",
}

local function encode_name(name)
    return (name:gsub("[^%w%._%-]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

function Access.response_head(result, size)
    local lines = {
        string.format("HTTP/1.1 %d %s", result.status, STATUS_TEXT[result.status] or "Error"),
        "Content-Type: " .. result.content_type,
        "Content-Length: " .. size,
        "Connection: close",
        result.cacheable and "Cache-Control: private, max-age=3600" or "Cache-Control: no-store",
        "Referrer-Policy: no-referrer",
        "X-Content-Type-Options: nosniff",
        "X-Frame-Options: DENY",
        "Content-Security-Policy: default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'",
    }
    if result.download_name then
        local safe = result.download_name:gsub("[^%w%._%-]", "_")
        lines[#lines + 1] = string.format("Content-Disposition: %s; filename=\"%s\"; filename*=UTF-8''%s",
            result.attachment and "attachment" or "inline", safe, encode_name(result.download_name))
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

return Access
