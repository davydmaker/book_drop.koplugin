package.path = "./?.lua;" .. package.path
local Access = require("book_drop/access")
local I18n = require("book_drop/i18n")
local Cover = require("book_drop/cover")

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

local TOKEN, HOST, PHONE, OTHER = "abc123token", "192.168.0.5:8642", "192.168.0.20", "192.168.0.99"
local function shots()
    return {
        { name = "shot.png", path = "/shots/shot.png", size = 10 },
        { name = "foto.jpg", path = "/shots/foto.jpg", size = 20 },
        { name = "<script>alert(1)</script>.png", path = "/shots/x.png", size = 5 },
        { name = "notas.txt", path = "/shots/notas.txt", size = 5 },
    }
end
local BOOKS = {
    { name = "um.epub", label = "um.epub", path = "/books/um.epub", size = 2048 },
    { name = "<b>dois</b>.pdf", label = "<b>dois</b>.pdf", path = "/books/dois.pdf", size = 3 * 1024 * 1024 },
    { name = "config.lua", label = "config.lua", path = "/books/config.lua", size = 4 },
}
local function new_access(language)
    local asked = {}
    local access = Access.new{
        token = TOKEN, host = HOST, strings = I18n[language or "pt"],
        read_cover = function(path)
            if path == "/books/um.epub" then return "\255\216\255img", "image/jpeg" end
        end,
        list_shots = shots,
        list_books = function() return BOOKS end,
        can_store = function(name, size)
            if name == "existe.epub" then return "exists" end
            if size == 999 then return "space" end
        end,
        build_zip = function() return { path = "/tmp/a.zip", size = 99 } end,
        on_new_client = function(ip) asked[#asked + 1] = ip end,
    }
    return access, asked
end
local function get(access, path, ip, host, method)
    return access:handle(string.format("%s %s HTTP/1.1\r\nHost: %s\r\n\r\n", method or "GET", path, host or HOST), ip or PHONE)
end
local function post(access, name, size, extra, path)
    local head = { string.format("POST %s HTTP/1.1", path or ("/" .. TOKEN .. "/upload")), "Host: " .. HOST }
    if name then head[#head + 1] = "X-File-Name: " .. name end
    if size then head[#head + 1] = "Content-Length: " .. size end
    for _, line in ipairs(extra or {}) do head[#head + 1] = line end
    return access:handle(table.concat(head, "\r\n") .. "\r\n\r\n", PHONE)
end
local function approved()
    local access = new_access()
    get(access, "/" .. TOKEN .. "/")
    access:approve(PHONE)
    get(access, "/" .. TOKEN .. "/shots")
    get(access, "/" .. TOKEN .. "/books")
    return access
end

test("accepts only private networks", function()
    eq(Access.is_private_ip("10.0.70.138"), true); eq(Access.is_private_ip("192.168.1.2"), true)
    eq(Access.is_private_ip("172.16.0.1"), true); eq(Access.is_private_ip("172.31.255.1"), true)
    eq(Access.is_private_ip("172.32.0.1"), false); eq(Access.is_private_ip("8.8.8.8"), false)
    eq(Access.is_private_ip("127.0.0.1"), false); eq(Access.is_private_ip("nil"), false); eq(Access.is_private_ip(nil), false)
end)
test("a wrong or missing code reveals nothing", function()
    local a = approved()
    for _, path in ipairs({ "/", "/wrong/", "/wrong/shot/1", "/favicon.ico", "/abc123token2/", "//abc123token/" }) do
        local r = get(a, path)
        eq(r.status, 404); eq(r.path, nil)
    end
end)
test("the first device needs permission on the Kindle", function()
    local a, asked = new_access()
    local r = get(a, "/" .. TOKEN .. "/")
    eq(r.status, 200); eq(r.body:find("Confirme no Kindle", 1, true) ~= nil, true)
    eq(asked[1], PHONE)
    eq(get(a, "/" .. TOKEN .. "/shot/1").path, nil)
    get(a, "/" .. TOKEN .. "/")
    eq(#asked, 1)
end)
test("after approval, serves the list and the files", function()
    local a = approved()
    local r = get(a, "/" .. TOKEN .. "/shots")
    eq(r.status, 200); eq(r.body:find("Baixar Tudo", 1, true) ~= nil, true)
    r = get(a, "/" .. TOKEN .. "/shot/2")
    eq(r.path, "/shots/foto.jpg"); eq(r.content_type, "image/jpeg")
    eq(get(a, "/" .. TOKEN .. "/all.zip").path, "/tmp/a.zip")
end)
test("allows one device only", function()
    local a = approved()
    eq(get(a, "/" .. TOKEN .. "/", OTHER).status, 404)
    eq(get(a, "/" .. TOKEN .. "/shot/1", OTHER).path, nil)
end)
test("a second device stays out while the first one waits", function()
    local a, asked = new_access()
    get(a, "/" .. TOKEN .. "/")
    eq(get(a, "/" .. TOKEN .. "/", OTHER).status, 404)
    eq(#asked, 1)
    a:approve(OTHER)
    eq(a.client_ip, nil)
end)
test("a denied device stays out", function()
    local a, asked = new_access()
    get(a, "/" .. TOKEN .. "/")
    a:deny(PHONE)
    eq(get(a, "/" .. TOKEN .. "/").close_only, true)
    eq(#asked, 1)
end)
test("cannot leave the folder", function()
    local a = approved()
    for _, path in ipairs({
        "/" .. TOKEN .. "/../../etc/passwd", "/" .. TOKEN .. "/shot/../../../etc/passwd", "/" .. TOKEN .. "/shot/1/../2",
        "/" .. TOKEN .. "/shot/%2e%2e%2fetc", "/" .. TOKEN .. "/shot.png", "/" .. TOKEN .. "/shot/shot.png", "/" .. TOKEN .. "/shot/-1",
        "/" .. TOKEN .. "/shot/0", "/" .. TOKEN .. "/shot/999", "/" .. TOKEN .. "/shot/1?x=/etc/passwd",
        "/" .. TOKEN .. "/book/../../settings.reader.lua", "/" .. TOKEN .. "/book/999",
    }) do
        local r = get(a, path)
        eq(r.status, 404); eq(r.path, nil)
    end
end)
test("screenshots serve only images, and books only book formats", function()
    local a = approved()
    eq(get(a, "/" .. TOKEN .. "/shot/4").path, nil)
    eq(get(a, "/" .. TOKEN .. "/book/1").path, "/books/um.epub")
    eq(get(a, "/" .. TOKEN .. "/book/3").path, nil)
end)
test("a book downloads as an attachment, without opening in the browser", function()
    local r = get(approved(), "/" .. TOKEN .. "/book/1")
    eq(r.attachment, true); eq(r.content_type, "application/octet-stream")
end)
test("numbers do not change when a new file appears", function()
    local a = approved()
    table.insert(BOOKS, 1, { name = "novo.epub", label = "novo.epub", path = "/books/novo.epub", size = 1 })
    eq(get(a, "/" .. TOKEN .. "/book/1").path, "/books/um.epub")
    table.remove(BOOKS, 1)
end)
test("a deleted file is no longer served", function()
    local a = approved()
    local removed = table.remove(BOOKS, 1)
    eq(get(a, "/" .. TOKEN .. "/book/1").path, nil)
    table.insert(BOOKS, 1, removed)
end)
test("a number never listed opens nothing", function()
    local a = new_access()
    get(a, "/" .. TOKEN .. "/")
    a:approve(PHONE)
    eq(get(a, "/" .. TOKEN .. "/book/1").path, nil)
end)
test("allowed methods", function()
    local a = approved()
    for _, method in ipairs({ "PUT", "DELETE", "HEAD", "OPTIONS" }) do
        eq(get(a, "/" .. TOKEN .. "/", PHONE, HOST, method).status, 404)
    end
    eq(get(a, "/" .. TOKEN .. "/", PHONE, HOST, "POST").status, 404)
end)
test("an accepted upload reports name and size", function()
    local r = post(approved(), "um%20livro.epub", "1000")
    eq(r.upload.name, "um livro.epub"); eq(r.upload.size, 1000)
end)
test("an upload needs an approved device", function()
    local a = new_access()
    eq(post(a, "um.epub", "10").status, 404)
    eq(a.pending_ip, nil)
    get(a, "/" .. TOKEN .. "/")
    eq(post(a, "um.epub", "10").status, 404)
end)
test("uploads only at the right address", function()
    local a = approved()
    eq(post(a, "um.epub", "10", nil, "/" .. TOKEN .. "/").status, 404)
    eq(post(a, "um.epub", "10", nil, "/errado/upload").status, 404)
end)
test("an upload refuses another origin", function()
    local a = approved()
    eq(post(a, "um.epub", "10", { "Origin: http://evil.example" }).status, 404)
    eq(post(a, "um.epub", "10", { "Origin: http://" .. HOST }).upload.name, "um.epub")
end)
test("an upload without its own header is refused, which blocks forms from other sites", function()
    eq(post(approved(), nil, "10").status, 404)
end)
test("an upload refuses an ambiguous size", function()
    local a = approved()
    eq(post(a, "um.epub", "10", { "Transfer-Encoding: chunked" }).status, 404)
    eq(post(a, "um.epub", "10", { "Content-Length: 99" }).status, 404)
    eq(post(a, "um.epub", nil).status, 400)
    eq(post(a, "um.epub", "0").status, 400)
    eq(post(a, "um.epub", "-5").status, 400)
    eq(post(a, "um.epub", "1e3").status, 400)
end)
test("an upload respects the size limit", function()
    local a = approved()
    eq(post(a, "um.epub", tostring(Access.MAX_UPLOAD_BYTES + 1)).status, 413)
    eq(post(a, "um.epub", tostring(Access.MAX_UPLOAD_BYTES)).upload.size, Access.MAX_UPLOAD_BYTES)
end)
test("an upload accepts only book formats", function()
    local a = approved()
    for _, name in ipairs({ "x.lua", "x.sh", "x.html", "x.png", "x.epub.sh", "semextensao" }) do
        local r = post(a, name, "10")
        eq(r.upload, nil); eq(r.status ~= 200, true)
    end
end)
test("an upload cannot choose a folder or a hidden file", function()
    local a = approved()
    for _, name in ipairs({ "../x.epub", "..%2fx.epub", "a/b.epub", "a%5Cb.epub", "%2Fetc%2Fx.epub", "x%00.epub", "x%0A.epub", "..", ".epub" }) do
        eq(post(a, name, "10").upload, nil)
    end
    eq(post(a, ".oculto.epub", "10").upload.name, "oculto.epub")
    eq(post(a, "%3Atitulo%3F.epub", "10").upload.name, "_titulo_.epub")
    eq(post(a, string.rep("a", 201) .. ".epub", "10").upload, nil)
end)
test("an upload neither replaces a file nor exceeds the free space", function()
    local a = approved()
    eq(post(a, "existe.epub", "10").status, 409)
    eq(post(a, "um.epub", "999").status, 507)
end)
test("the check before an upload follows the same rules", function()
    local a = approved()
    eq(get(a, "/" .. TOKEN .. "/can-upload?name=um.epub&size=10").status, 200)
    eq(get(a, "/" .. TOKEN .. "/can-upload?name=existe.epub&size=10").status, 409)
    eq(get(a, "/" .. TOKEN .. "/can-upload?name=x.sh&size=10").status, 415)
    eq(get(a, "/" .. TOKEN .. "/can-upload?name=%2E%2E%2Fx.epub&size=10").status, 400)
end)
test("a name with invalid UTF-8 is refused", function()
    local a = approved()
    eq(post(a, "%FFx.epub", "10").upload, nil)
    eq(post(a, "%C3x.epub", "10").upload, nil)
    eq(post(a, "A%C3%A7%C3%A3o.epub", "10").upload.name, "Ação.epub")
end)
test("the three languages have the same strings", function()
    for key in pairs(I18n.pt) do
        eq(I18n.en[key] ~= nil, true); eq(I18n.es[key] ~= nil, true)
    end
    for key in pairs(I18n.en) do eq(I18n.pt[key] ~= nil, true) end
    for key in pairs(I18n.es) do eq(I18n.pt[key] ~= nil, true) end
end)
test("the language comes from KOReader, with English for the others", function()
    eq(I18n.language_from("pt_BR"), "pt"); eq(I18n.language_from("es"), "es"); eq(I18n.language_from("en_US"), "en")
    eq(I18n.language_from("de"), "en"); eq(I18n.language_from(nil), "en"); eq(I18n.language_from("language_from"), "en")
end)
test("pages and script follow the language", function()
    for language, word in pairs({ pt = "Enviar para o Kindle", en = "Send to the Kindle", es = "Enviar al Kindle" }) do
        local a = new_access(language)
        get(a, "/" .. TOKEN .. "/")
        a:approve(PHONE)
        local r = get(a, "/" .. TOKEN .. "/")
        eq(r.body:find(word, 1, true) ~= nil, true)
        eq(r.body:find('lang="' .. I18n[language].html_lang .. '"', 1, true) ~= nil, true)
        local script = get(a, "/" .. TOKEN .. "/upload.js").body
        eq(script:find("%CHECKING%", 1, true), nil)
    end
end)
test("grid and list of books", function()
    local a = approved()
    local grid = get(a, "/" .. TOKEN .. "/books").body
    eq(grid:find('class="grid"', 1, true) ~= nil, true)
    eq(grid:find("/cover/1", 1, true) ~= nil, true)
    eq(grid:find("um<small>", 1, true) ~= nil, true)
    local list = get(a, "/" .. TOKEN .. "/books/list").body
    eq(list:find('class="row"', 1, true) ~= nil, true)
end)
test("a cover only for a listed book, with a placeholder when there is none", function()
    local a = approved()
    local r = get(a, "/" .. TOKEN .. "/cover/1")
    eq(r.content_type, "image/jpeg")
    r = get(a, "/" .. TOKEN .. "/cover/2")
    eq(r.content_type, "image/svg+xml"); eq(r.status, 200); eq(a.strikes[PHONE], nil)
    eq(get(a, "/" .. TOKEN .. "/cover/3").status, 404)
    eq(get(a, "/" .. TOKEN .. "/cover/999").status, 404)
    eq(get(a, "/" .. TOKEN .. "/cover/1", OTHER).status, 404)
end)
test("cover: the content decides the type", function()
    eq(Cover.image_type("\255\216\255abc"), "image/jpeg")
    eq(Cover.image_type("\137PNG\r\n\26\nabc"), "image/png")
    eq(Cover.image_type("<svg onload=alert(1)>"), nil)
    eq(Cover.image_type("<html><script>"), nil)
    eq(Cover.image_type(""), nil)
end)
test("cover: finds the image in the OPF", function()
    eq(Cover.opf_path('<container><rootfile full-path="OEBPS/content.opf" media-type="x"/></container>'), "OEBPS/content.opf")
    eq(Cover.opf_path("<container></container>"), nil)
    eq(Cover.find_href('<manifest><item id="a" href="x.jpg" media-type="image/jpeg" properties="cover-image"/></manifest>'), "x.jpg")
    eq(Cover.find_href('<meta name="cover" content="c1"/><item href="y.jpg" id="c1" media-type="image/jpeg"/>'), "y.jpg")
    eq(Cover.find_href("<meta content='c1' name='cover'/><item id='c1' href='y.jpg'/>"), "y.jpg")
    eq(Cover.find_href('<item id="capa-cover" href="img/z.png" media-type="image/png"/>'), "img/z.png")
    eq(Cover.find_href('<item id="cap1" href="c.html" media-type="application/xhtml+xml"/>'), nil)
    eq(Cover.resolve("OEBPS/content.opf", "../img/a%20b.jpg"), "img/a b.jpg")
    eq(Cover.resolve("content.opf", "./c.jpg"), "c.jpg")
    eq(Cover.resolve("a/b.opf", "../../../etc/passwd"), "etc/passwd")
end)
test("upload errors and readable sizes", function()
    local a = new_access()
    eq(a:upload_error("exists").status, 409); eq(a:upload_error("busy").status, 409)
    eq(a:upload_error("qualquer").status, 500); eq(a:upload_done().status, 201)
    eq(a:format_size(2048), "2 KB"); eq(a:format_size(3 * 1024 * 1024), "3,0 MB")
    eq(new_access("en"):format_size(3 * 1024 * 1024), "3.0 MB")
end)
test("refuses another Host, which blocks DNS rebinding", function()
    local a = approved()
    eq(get(a, "/" .. TOKEN .. "/", PHONE, "evil.example").status, 404)
    eq(get(a, "/" .. TOKEN .. "/", PHONE, "192.168.0.5").status, 404)
    eq(a:handle("GET /" .. TOKEN .. "/ HTTP/1.1\r\n\r\n", PHONE).status, 404)
end)
test("refuses an address outside the private network", function()
    eq(get(approved(), "/" .. TOKEN .. "/", "8.8.8.8").status, 404)
end)
test("refuses a request too large or malformed", function()
    local a = approved()
    eq(a:handle("GET /" .. TOKEN .. "/ HTTP/1.1\r\nHost: " .. HOST .. "\r\nX: " .. string.rep("a", 9000) .. "\r\n\r\n", PHONE).status, 404)
    eq(a:handle("lixo total\r\n\r\n", PHONE).status, 404)
    eq(a:handle("", PHONE).status, 404)
end)
test("a file name cannot inject HTML", function()
    local a = approved()
    local body = get(a, "/" .. TOKEN .. "/shots").body
    eq(body:find("<script>", 1, true), nil)
    eq(body:find("&lt;script&gt;", 1, true) ~= nil, true)
    body = get(a, "/" .. TOKEN .. "/books").body
    eq(body:find("<b>dois", 1, true), nil)
    eq(body:find("&lt;b&gt;dois", 1, true) ~= nil, true)
end)
test("too many invalid attempts block that address only", function()
    local a = approved()
    for _ = 1, Access.MAX_BAD_REQUESTS do get(a, "/wrong/", OTHER) end
    eq(get(a, "/" .. TOKEN .. "/", OTHER).close_only, true)
    eq(get(a, "/" .. TOKEN .. "/").status, 200)
end)
test("the approved device is never locked out by its own browser", function()
    local a = approved()
    for _ = 1, Access.MAX_BAD_REQUESTS * 2 do get(a, "/favicon.ico") end
    eq(a.denied[PHONE], nil)
    eq(get(a, "/" .. TOKEN .. "/").status, 200)
end)
test("names with overlong forms, surrogates or reversing controls are refused", function()
    local a = approved()
    for _, name in ipairs({ "%C0%AFx.epub", "%E0%80%AFx.epub", "%ED%A0%80x.epub", "%F4%90%80%80x.epub", "evil%E2%80%AEbupe.epub", "x%E2%81%A6.epub" }) do
        eq(post(a, name, "10").upload, nil)
    end
    eq(post(a, "Crian%C3%A7a %E2%80%94 um.epub", "10").upload.name, "Criança — um.epub")
end)
test("cover: crafted tags do not freeze the reader", function()
    local started = os.clock()
    eq(Cover.find_href(string.rep("<item ", 200000)), nil)
    eq(Cover.opf_path(string.rep("<rootfile ", 100000)), nil)
    eq(Cover.find_href(string.rep("<", 1000000)), nil)
    eq(Cover.find_href(string.rep("<item a='b'>", 80000)), nil)
    eq(os.clock() - started < 2, true)
end)
test("cover: only a ZIP of a reasonable size reaches the archive library", function()
    local path = os.tmpname()
    local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
    local function u32(n) return u16(n % 65536) .. u16(math.floor(n / 65536)) end
    local function zip(head, entries, directory)
        local file = io.open(path, "wb")
        file:write(head, string.rep("x", 200), "PK\5\6", u16(0), u16(0), u16(entries), u16(entries), u32(directory), u32(0), u16(0))
        file:close()
        return Cover.is_acceptable_zip(path)
    end
    eq(zip("PK\3\4", 10, 1000), true)
    eq(zip("\31\139\8\0", 10, 1000), false)
    eq(zip("7z\188\175", 10, 1000), false)
    eq(zip("PK\3\4", 65535, 1000), false)
    eq(zip("PK\3\4", 30000, 1000), false)
    eq(zip("PK\3\4", 10, 5 * 1024 * 1024), false)
    eq(zip("PK\3\4", 0, 0), false)
    local file = io.open(path, "wb")
    file:write("PK\3\4 without an end record")
    file:close()
    eq(Cover.is_acceptable_zip(path), false)
    os.remove(path)
    eq(Cover.is_acceptable_zip(path), false)
    eq(Cover.read("/nowhere/book.pdf"), nil)
end)
test("security headers", function()
    local head = Access.response_head({ status = 200, content_type = "image/png", download_name = 'a"b\r\nX: y.png' }, 10)
    eq(head:find("Cache-Control: no-store", 1, true) ~= nil, true)
    eq(head:find("Content-Security-Policy: default-src 'none'", 1, true) ~= nil, true)
    eq(head:find("X: y", 1, true), nil)
    eq(head:find('filename="a_b__X__y.png"', 1, true) ~= nil, true)
    eq(head:find("X: y", 1, true), nil)
    head = Access.response_head({ status = 200, content_type = "application/octet-stream", download_name = "Ação.epub", attachment = true }, 10)
    eq(head:find("Content-Disposition: attachment", 1, true) ~= nil, true)
    eq(head:find("filename*=UTF-8''A%C3%A7%C3%A3o.epub", 1, true) ~= nil, true)
    eq(head:find("connect-src 'self'", 1, true) ~= nil, true)
    eq(Access.response_head({ status = 200, content_type = "image/jpeg", cacheable = true }, 1):find("private, max-age", 1, true) ~= nil, true)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
