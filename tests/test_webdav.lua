-- @selfrun 本文件自包含运行（内部 os.exit），由 run_all.lua 以子进程方式调用
--[[--
wdr/webdav.lua 单测（桌面 Lua 5.1 运行）
-- @selfrun
-- 上面的标记让 tests/run_all.lua 用子进程方式运行本套件：
-- 本文件自己维护断言计数并在末尾 os.exit()，不适合被 dofile 到主进程里。

运行方式：
    cd /home/riko/koreader-plugin && ./tools/lua tests/test_webdav.lua

测试完全离线：网络依赖通过 package.loaded["socket.http"] / ["socketutil"] 注入假模块，
因此不需要（也不允许）真的连 WebDAV 服务器。

覆盖：
  1. joinUrl 的边界（根路径、末尾斜杠、中文、空格、重复斜杠、需转义字符）
  2. parseMultiStatus 的多种真实响应形态 + 目录自身剔除 + 各种错误样本
  3. 客户端各方法在假 HTTP 上的行为（list/download/upload/delete/move/mkdir/exists/request）
  4. 错误路径：401/403/404/412/503、传输层超时、配置错误、重定向提示
  5. 全局规约：每次请求前 set_timeout、请求后 reset_timeout

@module tests.test_webdav
--]]--

package.path = "webdavreader.koplugin/?.lua;./?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- 极简测试框架
-- ---------------------------------------------------------------------------

local pass_count, fail_count = 0, 0
local failures = {}
local current_case = nil

local function ok(cond, msg)
    if cond then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] %s", current_case or "?", msg or "assertion failed")
    end
    return cond
end

local function eq(actual, expected, msg)
    local cond = actual == expected
    if not cond then
        failures[#failures + 1] = string.format("[%s] %s\n      期望: %s\n      实际: %s",
            current_case or "?", msg or "值不相等",
            tostring(expected), tostring(actual))
        fail_count = fail_count + 1
        return false
    end
    pass_count = pass_count + 1
    return true
end

local function contains(haystack, needle, msg)
    local cond = type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
    if not cond then
        failures[#failures + 1] = string.format("[%s] %s\n      期望包含: %s\n      实际: %s",
            current_case or "?", msg or "字符串未包含子串",
            tostring(needle), tostring(haystack))
        fail_count = fail_count + 1
        return false
    end
    pass_count = pass_count + 1
    return true
end

local function test(name, fn)
    current_case = name
    local okrun, err = pcall(fn)
    if not okrun then
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] 抛出异常: %s", name, tostring(err))
        print(string.format("FAIL  %s", name))
    else
        print(string.format("ok    %s", name))
    end
    current_case = nil
end

-- ---------------------------------------------------------------------------
-- 假 http 模块（注入到 package.loaded["socket.http"]）
-- ---------------------------------------------------------------------------

local FakeHttp = {
    requests = {},
    handler = nil,
    reset_calls = 0,
    timeout_calls = 0,
    last_block_timeout = nil,
    last_total_timeout = nil,
}

function FakeHttp.reset()
    FakeHttp.requests = {}
    FakeHttp.handler = nil
    FakeHttp.reset_calls = 0
    FakeHttp.timeout_calls = 0
    FakeHttp.last_block_timeout = nil
    FakeHttp.last_total_timeout = nil
end

function FakeHttp.request(req)
    FakeHttp.requests[#FakeHttp.requests + 1] = req
    if not FakeHttp.handler then
        error("FakeHttp: 没有设置 handler")
    end
    return FakeHttp.handler(req)
end

local FakeSocketutil = {
    FILE_BLOCK_TIMEOUT = 15,
    FILE_TOTAL_TIMEOUT = 60,
}

function FakeSocketutil:set_timeout(block, total)
    FakeHttp.timeout_calls = FakeHttp.timeout_calls + 1
    FakeHttp.last_block_timeout = block
    FakeHttp.last_total_timeout = total
    return block, total
end

function FakeSocketutil:reset_timeout()
    FakeHttp.reset_calls = FakeHttp.reset_calls + 1
end

package.loaded["socket.http"] = FakeHttp
package.loaded["socketutil"] = FakeSocketutil

local WebDAV = require("wdr.webdav")

-- ---------------------------------------------------------------------------
-- 响应辅助
-- ---------------------------------------------------------------------------

--- 把 body 灌进 req.sink（分块，模拟真实 socket 分片）。
local function feedSink(sink, body, chunk_size)
    if not sink then return end
    chunk_size = chunk_size or 7
    local i = 1
    while i <= #body do
        local chunk = body:sub(i, i + chunk_size - 1)
        local ret, err = sink(chunk)
        if ret == nil then
            sink(nil, err)
            return false
        end
        i = i + chunk_size
    end
    sink(nil)
    return true
end

--- 把 req.source 读空（模拟 PUT 上传）。
local function drainSource(source)
    if not source then return nil end
    local out, loops = {}, 0
    while true do
        loops = loops + 1
        if loops > 10000 then error("source 反复返回数据，疑似死循环") end
        local chunk = source()
        if chunk == nil then break end
        out[#out + 1] = chunk
    end
    return table.concat(out)
end

--- 构造一个标准响应：把 body 写进 sink，返回 LuaSocket 形态的四元组。
local function respond(req, code, opts)
    opts = opts or {}
    if opts.body and req.sink then
        feedSink(req.sink, opts.body, opts.chunk_size)
    elseif req.sink then
        req.sink(nil)
    end
    return 1, code, opts.headers or {}, opts.status or ("HTTP/1.1 " .. tostring(code) .. " Test")
end

--- 传输层失败：LuaSocket 形态 (nil, err, headers, status)。
local function transportFailure(err, headers)
    return nil, err, headers or {}, err
end

-- ---------------------------------------------------------------------------
-- 1. joinUrl
-- ---------------------------------------------------------------------------

test("joinUrl：根路径（无末尾斜杠）", function()
    eq(WebDAV.joinUrl("https://example.com/dav", "", {}), "https://example.com/dav")
    eq(WebDAV.joinUrl("https://example.com/dav", nil), "https://example.com/dav")
end)

test("joinUrl：根路径带末尾斜杠选项", function()
    eq(WebDAV.joinUrl("https://example.com/dav", "", { trailing_slash = true }),
        "https://example.com/dav/")
end)

test("joinUrl：地址末尾已有斜杠不产生双斜杠", function()
    eq(WebDAV.joinUrl("https://example.com/dav/", "books/a.epub"), "https://example.com/dav/books/a.epub")
    eq(WebDAV.joinUrl("https://example.com/dav//", "books"), "https://example.com/dav/books")
    eq(WebDAV.joinUrl("https://example.com/dav/", "", { trailing_slash = true }),
        "https://example.com/dav/")
end)

test("joinUrl：path 的前导/尾部斜杠与重复斜杠被归一化", function()
    eq(WebDAV.joinUrl("https://example.com/dav", "/books/"), "https://example.com/dav/books")
    eq(WebDAV.joinUrl("https://example.com/dav", "a//b///c"), "https://example.com/dav/a/b/c")
    eq(WebDAV.joinUrl("https://example.com/dav", "///"), "https://example.com/dav")
end)

test("joinUrl：中文路径被百分号编码，斜杠保留", function()
    eq(WebDAV.joinUrl("https://example.com/dav", "书库/三体.txt"),
        "https://example.com/dav/%E4%B9%A6%E5%BA%93/%E4%B8%89%E4%BD%93.txt")
end)

test("joinUrl：空格与非保留字符被编码", function()
    eq(WebDAV.joinUrl("https://example.com/dav", "my books/a b.epub"),
        "https://example.com/dav/my%20books/a%20b.epub")
    -- ? & = # 在路径里必须编码，否则会被服务器当成 query / fragment
    eq(WebDAV.joinUrl("https://example.com/dav", "a?b&c=d#e"),
        "https://example.com/dav/a%3Fb%26c%3Dd%23e")
    -- unreserved 集合保持原样
    eq(WebDAV.joinUrl("https://example.com/dav", "A-z_0.9~x"), "https://example.com/dav/A-z_0.9~x")
end)

test("joinUrl：trailing_slash 对子路径也生效", function()
    eq(WebDAV.joinUrl("https://example.com/dav", "books", { trailing_slash = true }),
        "https://example.com/dav/books/")
    -- 已带斜杠时不会双写
    eq(WebDAV.joinUrl("https://example.com/dav", "books/", { trailing_slash = true }),
        "https://example.com/dav/books/")
end)

test("joinUrl：百分号本身被编码成 %25（不会二次解码出问题）", function()
    eq(WebDAV.joinUrl("https://example.com/dav", "100%.txt"), "https://example.com/dav/100%25.txt")
end)

-- ---------------------------------------------------------------------------
-- 2. parseMultiStatus
-- ---------------------------------------------------------------------------

-- Nextcloud / SabreDAV 形态：小写 d: 前缀 + lp1 命名空间 + 完整 URL href + 目录自身条目
local NC_XML = [[<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/riko/%E4%B9%A6%E5%BA%93/</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
    <d:getlastmodified>Tue, 12 Nov 2024 09:30:15 GMT</d:getlastmodified>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/riko/%E4%B9%A6%E5%BA%93/%E4%B8%89%E4%BD%93.txt</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype/>
    <d:getcontentlength>10240</d:getcontentlength>
    <d:getlastmodified>Tue, 12 Nov 2024 09:30:15 GMT</d:getlastmodified>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/riko/%E4%B9%A6%E5%BA%93/sub%20dir/</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
</d:multistatus>]]

test("parseMultiStatus：Nextcloud 风格（小写 d:、完整 URL href、中文）", function()
    local items, err = WebDAV.parseMultiStatus(NC_XML, {
        address = "https://cloud.example.com/remote.php/dav/files/riko",
        self_path = "书库",
    })
    eq(err, nil, "不应有错误")
    ok(items ~= nil, "应返回 items")
    eq(#items, 2, "目录自身条目应被剔除，只剩 2 个子项")

    local file = items[1]
    eq(file.name, "三体.txt", "中文文件名需正确 urlDecode")
    eq(file.is_folder, false)
    eq(file.size, 10240)
    eq(file.modified, 1731403815, "GMT 时间应换算成正确 unix 秒")
    eq(file.path, "书库/三体.txt")

    local sub = items[2]
    eq(sub.name, "sub dir", "空格需从 %20 还原")
    eq(sub.is_folder, true, "collection 应识别为目录")
    eq(sub.path, "书库/sub dir")
end)

test("parseMultiStatus：self_href 用完整 URL 也能剔除自身", function()
    local items = WebDAV.parseMultiStatus(NC_XML, {
        address = "https://cloud.example.com/remote.php/dav/files/riko",
        self_href = "https://cloud.example.com/remote.php/dav/files/riko/%E4%B9%A6%E5%BA%93/",
    })
    eq(#items, 2)
    eq(items[1].name, "三体.txt")
end)

-- Apache mod_dav 形态：大写 D: 前缀、元素顺序变化、propstat 含 404 分支
local APACHE_XML = [[<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response>
<D:href>/dav/books/</D:href>
<D:propstat>
<D:prop>
<D:getlastmodified>Tue, 12 Nov 2024 09:30:15 GMT</D:getlastmodified>
<D:resourcetype><D:collection/></D:resourcetype>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
</D:propstat>
</D:response>
<D:response>
<D:href>/dav/books/a%20b.epub</D:href>
<D:propstat>
<D:prop>
<D:getlastmodified>Tue, 12 Nov 2024 09:30:15 GMT</D:getlastmodified>
<D:resourcetype/>
<D:getcontentlength>123</D:getcontentlength>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
</D:propstat>
<D:propstat>
<D:prop><D:getcontenttype/></D:prop>
<D:status>HTTP/1.1 404 Not Found</D:status>
</D:propstat>
</D:response>
<D:response>
<D:href>/dav/books/%E4%B8%AD%E6%96%87.epub</D:href>
<D:propstat>
<D:prop>
<D:resourcetype/>
<D:getcontentlength>7</D:getcontentlength>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
</D:propstat>
</D:response>
</D:multistatus>]]

test("parseMultiStatus：Apache mod_dav 风格（大写 D:、元素顺序变化）", function()
    local items, err = WebDAV.parseMultiStatus(APACHE_XML, {
        address = "https://example.com/dav",
        self_path = "books",
    })
    eq(err, nil)
    eq(#items, 2, "propstat 里的 404 不算错误，目录自身被剔除")
    eq(items[1].name, "a b.epub")
    eq(items[1].size, 123)
    eq(items[1].is_folder, false)
    eq(items[1].modified, 1731403815)
    eq(items[2].name, "中文.epub")
    eq(items[2].size, 7)
    eq(items[2].path, "books/中文.epub")
end)

-- 无命名空间前缀（部分简易实现）+ 属性顺序变化 + 自闭合标签 + iscollection
local BARE_XML = [[<?xml version="1.0" encoding="utf-8"?>
<multistatus xmlns="DAV:">
 <response>
  <href>/books/</href>
  <propstat>
   <prop>
    <resourcetype><collection/></resourcetype>
   </prop>
   <status>HTTP/1.1 200 OK</status>
  </propstat>
 </response>
 <response>
  <propstat>
   <prop>
    <getcontentlength>2048</getcontentlength>
    <resourcetype />
    <getlastmodified>2024-11-12T17:30:15+08:00</getlastmodified>
   </prop>
   <status>HTTP/1.1 200 OK</status>
  </propstat>
  <href>/books/b.epub</href>
 </response>
 <response>
  <href>/books/c.txt</href>
  <propstat>
   <prop>
    <iscollection>0</iscollection>
    <getcontentlength />
   </prop>
   <status>HTTP/1.1 200 OK</status>
  </propstat>
 </response>
</multistatus>]]

test("parseMultiStatus：无前缀 + 自闭合 + 元素顺序变化 + ISO8601 时间", function()
    local items, err = WebDAV.parseMultiStatus(BARE_XML, {
        address = "https://example.com",
        self_path = "books",
    })
    eq(err, nil)
    eq(#items, 2)
    eq(items[1].name, "b.epub")
    eq(items[1].size, 2048)
    eq(items[1].modified, 1731403815, "带 +08:00 偏移的 ISO8601 应换算成 UTC")
    eq(items[2].name, "c.txt")
    eq(items[2].size, nil, "空元素 getcontentlength 应为 nil 而不是崩")
    eq(items[2].is_folder, false)
end)

test("parseMultiStatus：&amp; 实体在 href 中被还原", function()
    local xml = [[<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response>
  <d:href>/dav/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/Tom%20%26%20Jerry.epub</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>5</d:getcontentlength></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/a&amp;b.txt</d:href>
  <d:propstat><d:prop><d:resourcetype/></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>]]
    local items, err = WebDAV.parseMultiStatus(xml, { address = "https://example.com/dav" })
    eq(err, nil)
    eq(#items, 2)
    eq(items[1].name, "Tom & Jerry.epub", "%20 与 %26 都要还原")
    eq(items[2].name, "a&b.txt", "XML 实体 &amp; 要还原")
end)

test("parseMultiStatus：response 级 404 的条目被丢弃", function()
    local xml = [[<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response>
  <d:href>/dav/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/gone.txt</d:href>
  <d:status>HTTP/1.1 404 Not Found</d:status>
 </d:response>
 <d:response>
  <d:href>/dav/ok.txt</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>9</d:getcontentlength></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>]]
    local items, err = WebDAV.parseMultiStatus(xml, { address = "https://example.com/dav" })
    eq(err, nil)
    eq(#items, 1, "403/404 的 response 不是目录子项")
    eq(items[1].name, "ok.txt")
    eq(items[1].size, 9)
end)

test("parseMultiStatus：目录自身只能用 href 结尾斜杠识别时也能剔除", function()
    local xml = [[<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
 <D:response>
  <D:href>/dav/dir/</D:href>
  <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
   <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
 </D:response>
 <D:response>
  <D:href>/dav/dir/x.epub</D:href>
  <D:propstat><D:prop><D:resourcetype/></D:prop>
   <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
 </D:response>
</D:multistatus>]]
    local items, err = WebDAV.parseMultiStatus(xml, {
        address = "https://example.com/dav",
        self_path = "dir",
    })
    eq(err, nil)
    eq(#items, 1)
    eq(items[1].name, "x.epub")
    eq(items[1].path, "dir/x.epub")
end)

test("parseMultiStatus：忽略注释、XML 声明与未知扩展元素", function()
    local xml = [[
<?xml version="1.0" encoding="utf-8"?>
<!-- DAV 响应 -->
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/dav/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/x.epub</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype/>
    <oc:fileid>42</oc:fileid>
    <oc:size>77</oc:size>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
</d:multistatus>
]]
    local items, err = WebDAV.parseMultiStatus(xml, { address = "https://example.com/dav" })
    eq(err, nil)
    eq(#items, 1)
    eq(items[1].name, "x.epub")
    eq(items[1].size, nil, "oc:size 不是标准字段，不应误读")
end)

test("parseMultiStatus：属性顺序/引号变化不影响解析", function()
    local xml = [[<d:multistatus xmlns:d='DAV:' >
 <d:response>
  <d:href >/dav/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection></d:collection></d:resourcetype></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/y%20z.epub</d:href>
  <d:propstat><d:prop>
   <d:getcontentlength >42</d:getcontentlength>
   <d:resourcetype />
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>]]
    local items, err = WebDAV.parseMultiStatus(xml, { address = "https://example.com/dav" })
    eq(err, nil)
    eq(#items, 1)
    eq(items[1].name, "y z.epub")
    eq(items[1].size, 42)
end)

test("parseMultiStatus：错误样本返回 nil, err 而不崩溃", function()
    local cases = {
        { "", "Empty response" },
        { "   \n\t ", "Empty response" },
        { "not xml at all", "not XML" },
        { "{}", "not XML" },
        { "<html><body><h1>503 Service Unavailable</h1></body></html>", "HTML page" },
        { "<?xml version='1.0'?><a:propstat xmlns:a='DAV:'></a:propstat>", "Multi-Status" },
        { "<d:multistatus xmlns:d='DAV:'></d:multistatus>", nil }, -- 空但没有条目
    }
    for i, case in ipairs(cases) do
        local items, err = WebDAV.parseMultiStatus(case[1], {})
        if case[2] == nil then
            ok(items ~= nil, "case " .. i .. "：合法空文档应返回空表")
            eq(#items, 0)
            eq(err, nil)
        else
            ok(items == nil, "case " .. i .. "：应返回 nil items")
            contains(err, case[2], "case " .. i .. "：错误信息应说明原因")
        end
    end
    local items, err = WebDAV.parseMultiStatus(nil, {})
    ok(items == nil, "nil 输入不应崩溃")
    ok(err ~= nil, "nil 输入应给出错误")
    local items2, err2 = WebDAV.parseMultiStatus(123, {})
    ok(items2 == nil and err2 ~= nil, "非字符串输入不应崩溃")
end)

test("parseMultiStatus：被截断的 XML 不崩溃", function()
    local truncated = [[<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response>
      <d:href>/dav/a.epub</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>10</d:getcontentlength></d:prop>]]
    local items, err = WebDAV.parseMultiStatus(truncated, { address = "https://example.com/dav" })
    eq(err, nil, "截断的文档仍能提取已完整出现的条目")
    eq(#items, 1)
    eq(items[1].size, 10)
end)

-- ---------------------------------------------------------------------------
-- 3. 客户端：list
-- ---------------------------------------------------------------------------

local SERVER = {
    address = "https://example.com/dav",
    username = "riko",
    password = "secret",
    start_dir = "/",
}

test("client:list 成功：PROPFIND 请求形态正确 + 返回子项", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 207, { body = NC_XML })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(err, nil)
    ok(items ~= nil)
    -- 目录自身（NC_XML 的 /remote.php/... /书库/）在 address 前缀不一致的情况下
    -- 只能靠 href 末尾斜杠识别，因此这里用同前缀的响应更严谨：
    eq(#FakeHttp.requests, 1)
    local req = FakeHttp.requests[1]
    eq(req.method, "PROPFIND")
    eq(req.url, "https://example.com/dav/")
    eq(req.headers["Depth"], "1")
    contains(req.headers["Content-Type"], "xml")
    eq(req.user, "riko")
    eq(req.password, "secret")
    ok(req.source ~= nil, "PROPFIND 必须带请求体")
end)

test("client:list 请求体是合法的 propfind", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        local body = drainSource(req.source) or ""
        ok(body:find("propfind", 1, true) ~= nil, "请求体应含 propfind")
        ok(body:find("resourcetype", 1, true) ~= nil, "应请求 resourcetype")
        ok(body:find("getcontentlength", 1, true) ~= nil, "应请求 getcontentlength")
        ok(body:find("getlastmodified", 1, true) ~= nil, "应请求 getlastmodified")
        return respond(req, 207, {
            headers = { ["Content-Type"] = "application/xml" },
            body = [[<d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/dav/</d:href>
                <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
                <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            </d:multistatus>]],
        })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(err, nil)
    eq(#items, 0, "只有自身条目时应返回空表")
end)

test("client:list 子目录：URL 以相对路径 + 末尾斜杠构造并编码中文", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 207, { body = [[<d:multistatus xmlns:d="DAV:"></d:multistatus>]] })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("书库/三体")
    eq(err, nil)
    eq(FakeHttp.requests[1].url, "https://example.com/dav/%E4%B9%A6%E5%BA%93/%E4%B8%89%E4%BD%93/")
end)

test("client:list 401 返回人类可读错误", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 401, { status = "HTTP/1.1 401 Unauthorized" })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(items, nil)
    contains(err, "HTTP 401")
    contains(err, "Unauthorized")
end)

test("client:list 403/404/500/503 都带状态码", function()
    for _, code in ipairs({ 403, 404, 500, 503 }) do
        FakeHttp.reset()
        FakeHttp.handler = function(req)
            return respond(req, code)
        end
        local client = WebDAV.client(SERVER)
        local items, err = client:list("")
        eq(items, nil)
        contains(err, "HTTP " .. code, "状态码 " .. code .. " 应出现在错误里")
    end
end)

test("client:list 301/302 给出重定向提示", function()
    for _, code in ipairs({ 301, 302 }) do
        FakeHttp.reset()
        FakeHttp.handler = function(req)
            return respond(req, code, { headers = { location = "https://other.example.com/dav/" } })
        end
        local client = WebDAV.client(SERVER)
        local items, err = client:list("")
        eq(items, nil)
        contains(err, "redirect", "重定向要明确提示，不能静默当成空目录")
    end
end)

test("client:list 非 207（如 200）视为错误", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 200, { body = "<html>hi</html>" })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(items, nil, "契约要求 207 之外视为错误")
    contains(err, "HTTP 200")
end)

test("client:list 传输层失败（超时）折算成英文短句", function()
    FakeHttp.reset()
    FakeHttp.handler = function() return transportFailure("timeout") end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(items, nil)
    contains(err, "timed out")
end)

test("client:list 地址无效时直接报配置错误，不发请求", function()
    FakeHttp.reset()
    FakeHttp.handler = function() error("不应发出请求") end
    local c1 = WebDAV.client({ address = "" })
    local items, err = c1:list("")
    eq(items, nil)
    contains(err, "address")

    local c2 = WebDAV.client({ address = "example.com/dav" })
    local items2, err2 = c2:list("")
    eq(items2, nil)
    contains(err2, "http://")
    eq(#FakeHttp.requests, 0, "配置错误时不应发出任何 HTTP 请求")
end)

-- ---------------------------------------------------------------------------
-- 4. 客户端：download / upload
-- ---------------------------------------------------------------------------

local function tempPath(name)
    local dir = os.getenv("TMPDIR") or "/tmp"
    return dir .. "/wdr-test-" .. tostring(os.time()) .. "-" .. name
end

test("client:download 成功：写入文件 + 进度回调", function()
    FakeHttp.reset()
    local body = string.rep("0123456789", 100) -- 1000 字节
    FakeHttp.handler = function(req)
        return respond(req, 200, {
            headers = { ["Content-Length"] = tostring(#body) },
            body = body,
        })
    end
    local client = WebDAV.client(SERVER)
    local seen = {}
    local local_path = tempPath("dl.bin")
    local okd, err = client:download("books/a b.epub", local_path, {
        progress_cb = function(downloaded, total)
            seen[#seen + 1] = { downloaded, total }
        end,
    })
    eq(err, nil)
    eq(okd, true)

    local req = FakeHttp.requests[1]
    eq(req.method, "GET")
    eq(req.url, "https://example.com/dav/books/a%20b.epub")

    local fh = io.open(local_path, "rb")
    ok(fh ~= nil, "本地文件应存在")
    local content = fh:read("*all")
    fh:close()
    eq(#content, #body, "落盘内容长度应与响应一致")
    eq(content, body)

    ok(#seen > 0, "必须调用 progress_cb")
    eq(seen[#seen][1], #body, "最后一次回调的已下载字节数应等于总长")
    eq(seen[#seen][2], #body, "最后一次回调应带上总长")
    os.remove(local_path)
end)

test("client:download 404：返回错误且不留半截文件", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 404) end
    local client = WebDAV.client(SERVER)
    local local_path = tempPath("missing.bin")
    local okd, err = client:download("nope.epub", local_path)
    eq(okd, nil)
    contains(err, "HTTP 404")
    local fh = io.open(local_path, "rb")
    ok(fh == nil, "失败时不应留下空文件")
    if fh then fh:close() end
end)

test("client:download 内容长度不足时报错", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 200, {
            headers = { ["Content-Length"] = "1000" },
            body = "short",
        })
    end
    local client = WebDAV.client(SERVER)
    local local_path = tempPath("short.bin")
    local okd, err = client:download("a.epub", local_path)
    eq(okd, nil)
    contains(err, "incomplete")
    os.remove(local_path)
end)

test("client:download 本地路径不可写时报错而不是崩溃", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 200, { body = "x" }) end
    local client = WebDAV.client(SERVER)
    local okd, err = client:download("a.epub", "/nonexistent-dir-xyz/a.bin")
    eq(okd, nil)
    contains(err, "local file")
end)

test("client:upload：PUT + Content-Length + 完整请求体", function()
    FakeHttp.reset()
    local local_path = tempPath("up.bin")
    local content = "hello webdav 中文"
    local fh = io.open(local_path, "wb")
    fh:write(content)
    fh:close()

    local uploaded = nil
    FakeHttp.handler = function(req)
        uploaded = drainSource(req.source)
        return respond(req, 201)
    end
    local client = WebDAV.client(SERVER)
    local oku, err = client:upload(local_path, "books/新 文件.bin")
    eq(err, nil)
    eq(oku, true)

    local req = FakeHttp.requests[1]
    eq(req.method, "PUT")
    eq(req.url, "https://example.com/dav/books/%E6%96%B0%20%E6%96%87%E4%BB%B6.bin")
    eq(req.headers["Content-Length"], tostring(#content))
    eq(uploaded, content, "上传内容必须完整")
    os.remove(local_path)
end)

test("client:upload 失败（507）返回错误", function()
    FakeHttp.reset()
    local local_path = tempPath("up2.bin")
    local fh = io.open(local_path, "wb")
    fh:write("x")
    fh:close()
    FakeHttp.handler = function(req)
        drainSource(req.source)
        return respond(req, 507)
    end
    local client = WebDAV.client(SERVER)
    local oku, err = client:upload(local_path, "a.bin")
    eq(oku, nil)
    contains(err, "507")
    os.remove(local_path)
end)

test("client:upload 本地文件不存在时报错", function()
    FakeHttp.reset()
    FakeHttp.handler = function() error("不应发出请求") end
    local client = WebDAV.client(SERVER)
    local oku, err = client:upload("/no/such/file-xyz.bin", "a.bin")
    eq(oku, nil)
    contains(err, "local file")
    eq(#FakeHttp.requests, 0)
end)

-- ---------------------------------------------------------------------------
-- 5. 客户端：delete / move / mkdir / exists / request
-- ---------------------------------------------------------------------------

test("client:delete 成功（204）", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 204) end
    local client = WebDAV.client(SERVER)
    local okd, err = client:delete("books/a.epub")
    eq(err, nil)
    eq(okd, true)
    eq(FakeHttp.requests[1].method, "DELETE")
    eq(FakeHttp.requests[1].url, "https://example.com/dav/books/a.epub")
end)

test("client:delete 404 返回错误", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 404) end
    local client = WebDAV.client(SERVER)
    local okd, err = client:delete("gone.epub")
    eq(okd, nil)
    contains(err, "HTTP 404")
end)

test("client:move：Destination 是绝对 URL 且被正确编码，Overwrite=F", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 201) end
    local client = WebDAV.client(SERVER)
    local okm, err = client:move("books/a b.epub", "存档/新名字.epub")
    eq(err, nil)
    eq(okm, true)
    local req = FakeHttp.requests[1]
    eq(req.method, "MOVE")
    eq(req.url, "https://example.com/dav/books/a%20b.epub")
    eq(req.headers["Destination"],
        "https://example.com/dav/%E5%AD%98%E6%A1%A3/%E6%96%B0%E5%90%8D%E5%AD%97.epub",
        "Destination 必须是绝对 URL 且已编码")
    eq(req.headers["Overwrite"], "F", "契约要求目标已存在时服务器拒绝")
end)

test("client:move 412（目标已存在）给出明确错误", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 412) end
    local client = WebDAV.client(SERVER)
    local okm, err = client:move("a.epub", "b.epub")
    eq(okm, nil)
    contains(err, "412")
    contains(err, "already exists")
end)

test("client:move 源与目标相同 / 为空时提前报错", function()
    FakeHttp.reset()
    FakeHttp.handler = function() error("不应发出请求") end
    local client = WebDAV.client(SERVER)
    local ok1, err1 = client:move("a/b.epub", "a/b.epub")
    eq(ok1, nil)
    ok(err1 ~= nil)
    local ok2, err2 = client:move("", "b.epub")
    eq(ok2, nil)
    ok(err2 ~= nil)
    eq(#FakeHttp.requests, 0)
end)

test("client:mkdir：MKCOL 到编码后的路径", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 201) end
    local client = WebDAV.client(SERVER)
    local okm, err = client:mkdir("新 目录")
    eq(err, nil)
    eq(okm, true)
    eq(FakeHttp.requests[1].method, "MKCOL")
    eq(FakeHttp.requests[1].url, "https://example.com/dav/%E6%96%B0%20%E7%9B%AE%E5%BD%95")
end)

test("client:mkdir 405 提示目录已存在", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 405) end
    local client = WebDAV.client(SERVER)
    local okm, err = client:mkdir("already")
    eq(okm, nil)
    contains(err, "405")
    contains(err, "already exists")
end)

test("client:exists 目录：true, true", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 207, { body = [[<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/books/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>]] })
    end
    local client = WebDAV.client(SERVER)
    local exists, is_folder, err = client:exists("books")
    eq(err, nil)
    eq(exists, true)
    eq(is_folder, true)
    eq(FakeHttp.requests[1].headers["Depth"], "0", "exists 用 Depth:0 只探测自身")
end)

test("client:exists 文件：true, false", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 207, { body = [[<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/a.epub</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>]] })
    end
    local client = WebDAV.client(SERVER)
    local exists, is_folder = client:exists("a.epub")
    eq(exists, true)
    eq(is_folder, false)
end)

test("client:exists 404：false, nil, nil", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 404) end
    local client = WebDAV.client(SERVER)
    local exists, is_folder, err = client:exists("nope")
    eq(exists, false)
    eq(is_folder, nil)
    eq(err, nil, "路径不存在不是错误")
end)

test("client:request 返回 ok, status_code, body", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 200, { body = "hello" })
    end
    local client = WebDAV.client(SERVER)
    local okr, code, body = client:request("GET", "a.txt")
    eq(okr, true)
    eq(code, 200)
    eq(body, "hello")
end)

test("client:request 非 2xx：false + 状态码 + 原始 body", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 500, { body = "<error>boom</error>" })
    end
    local client = WebDAV.client(SERVER)
    local okr, code, body = client:request("GET", "a.txt")
    eq(okr, false)
    eq(code, 500)
    eq(body, "<error>boom</error>")
end)

-- ---------------------------------------------------------------------------
-- 6. 全局规约：超时设置与复位
-- ---------------------------------------------------------------------------

test("每个请求前 set_timeout、请求后 reset_timeout", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 204) end
    local client = WebDAV.client(SERVER)
    client:delete("a")
    eq(FakeHttp.timeout_calls, 1)
    eq(FakeHttp.reset_calls, 1)
    eq(FakeHttp.last_block_timeout, 15, "默认应使用 socketutil.FILE_BLOCK_TIMEOUT")
    eq(FakeHttp.last_total_timeout, 60, "默认应使用 socketutil.FILE_TOTAL_TIMEOUT")
end)

test("自定义超时会传到 socketutil", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 204) end
    local client = WebDAV.client(SERVER, { timeout_block = 5, timeout_total = 20 })
    client:delete("a")
    eq(FakeHttp.last_block_timeout, 5)
    eq(FakeHttp.last_total_timeout, 20)
end)

test("请求抛异常时同样 reset_timeout", function()
    FakeHttp.reset()
    FakeHttp.handler = function() error("boom") end
    local client = WebDAV.client(SERVER)
    local okd, err = client:delete("a")
    eq(okd, nil)
    ok(err ~= nil)
    eq(FakeHttp.reset_calls, 1, "即使 http.request 抛错也必须复位超时")
end)

-- ---------------------------------------------------------------------------
-- 7. 客户端不修改传入的 server 表
-- ---------------------------------------------------------------------------

test("WebDAV.client 不修改传入的 server 表", function()
    local server = {
        address = "https://example.com/dav/",
        username = "u",
        password = "p",
        start_dir = "/books",
    }
    local before = {
        address = server.address,
        username = server.username,
        password = server.password,
        start_dir = server.start_dir,
    }
    local client = WebDAV.client(server)
    eq(server.address, before.address)
    eq(server.username, before.username)
    eq(server.password, before.password)
    eq(server.start_dir, before.start_dir)
    eq(client.address, "https://example.com/dav", "客户端内部会去掉尾部斜杠")
end)

test("两个客户端互不影响", function()
    local c1 = WebDAV.client({ address = "https://a.example.com/dav", username = "a" })
    local c2 = WebDAV.client({ address = "https://b.example.com/dav", username = "b" })
    eq(c1.address, "https://a.example.com/dav")
    eq(c2.address, "https://b.example.com/dav")
    eq(c1.username, "a")
    eq(c2.username, "b")
end)

-- ---------------------------------------------------------------------------
-- 8. 与 KOReader 真实实现的兼容性（util / ltn12）
-- ---------------------------------------------------------------------------

-- 桌面环境没有 KOReader 的 util / ltn12，这里按 frontend/util.lua 与 ltn12 的
-- 真实语义写等价 shim 注入，确认生产路径（不是兜底路径）行为一致。
local koreaderUtil = {
    --- 复制自 /tmp/koreader-ref/frontend/util.lua 的 util.urlEncode 实现
    urlEncode = function(url, preserve_chars)
        if url == nil then return nil end
        preserve_chars = preserve_chars or ""
        local pattern = string.format("([%s%s])", "^%w%-%._~", preserve_chars)
        url = url:gsub("\n", "\r\n")
        return (url:gsub(pattern, function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    end,
    --- 复制自 frontend/util.lua 的 util.urlDecode 实现
    urlDecode = function(url)
        if url == nil then return nil end
        return (url:gsub("%%(%x%x)", function(x)
            return string.char(tonumber(x, 16))
        end))
    end,
    --- 与 frontend/util.lua 的 HTML_ENTITIES_TO_UTF8 表等价（只列常用项）
    htmlEntitiesToUtf8 = function(text)
        if type(text) ~= "string" then return text end
        text = text:gsub("&lt;", "<")
        text = text:gsub("&gt;", ">")
        text = text:gsub("&quot;", '"')
        text = text:gsub("&apos;", "'")
        text = text:gsub("&nbsp;", " ")
        text = text:gsub("&#(%d+);", function(d) return string.char(tonumber(d)) end)
        text = text:gsub("&amp;", "&") -- 必须最后
        return text
    end,
}

local fakeLtn12 = {
    source = {
        string = function(s)
            local sent = false
            return function()
                if sent then return nil end
                sent = true
                return s
            end
        end,
        file = function(handle)
            if not handle then return nil, "unable to open file" end
            return function()
                local chunk = handle:read(4096)
                if chunk == nil then
                    handle:close()
                end
                return chunk
            end
        end,
    },
    sink = {
        table = function(t)
            return function(chunk)
                if chunk then t[#t + 1] = chunk end
                return 1
            end
        end,
        file = function(handle)
            return function(chunk)
                if chunk then
                    local okw, err = handle:write(chunk)
                    if not okw then return nil, err end
                    return 1
                end
                handle:close()
                return 1
            end
        end,
    },
}

--- 切换到「KOReader 生产依赖」形态。
local function useKoreaderDeps()
    WebDAV.setDependencies({
        http = FakeHttp,
        socketutil = FakeSocketutil,
        util = koreaderUtil,
        ltn12 = fakeLtn12,
    })
end

--- 恢复默认（走 package.loaded，即测试里的假 http + 内置兜底 util/ltn12）。
local function useFallbackDeps()
    WebDAV.setDependencies(nil)
end

test("注入 KOReader 版 util 后 joinUrl 行为不变", function()
    useKoreaderDeps()
    local okrun, err = pcall(function()
        eq(WebDAV.joinUrl("https://example.com/dav", "书库/三体 1.txt"),
            "https://example.com/dav/%E4%B9%A6%E5%BA%93/%E4%B8%89%E4%BD%93%201.txt")
        eq(WebDAV.joinUrl("https://example.com/dav", "a//b/"),
            "https://example.com/dav/a/b")
        eq(WebDAV.joinUrl("https://example.com/dav", "100%.txt"),
            "https://example.com/dav/100%25.txt")
    end)
    useFallbackDeps()
    if not okrun then error(err) end
end)

test("注入 KOReader 版 util 后 parseMultiStatus 行为不变", function()
    useKoreaderDeps()
    local okrun, err = pcall(function()
        local items, perr = WebDAV.parseMultiStatus(NC_XML, {
            address = "https://cloud.example.com/remote.php/dav/files/riko",
            self_path = "书库",
        })
        eq(perr, nil)
        eq(#items, 2)
        eq(items[1].name, "三体.txt")
        eq(items[1].size, 10240)
        eq(items[1].modified, 1731403815)
    end)
    useFallbackDeps()
    if not okrun then error(err) end
end)

test("注入 KOReader 版 ltn12 后整套请求流程可用", function()
    useKoreaderDeps()
    local okrun, err = pcall(function()
        -- list：ltn12.source.string 提供请求体，ltn12.sink.table 收响应体
        FakeHttp.reset()
        FakeHttp.handler = function(req)
            local sent = drainSource(req.source)
            ok(sent and sent:find("propfind", 1, true) ~= nil, "请求体应经 ltn12.source.string 发出")
            return respond(req, 207, { body = NC_XML })
        end
        local client = WebDAV.client({
            address = "https://cloud.example.com/remote.php/dav/files/riko",
        })
        local items, lerr = client:list("书库")
        eq(lerr, nil)
        eq(#items, 2)

        -- download：ltn12.sink.file 落盘
        FakeHttp.reset()
        FakeHttp.handler = function(req)
            return respond(req, 200, { body = "abcdef", headers = { ["Content-Length"] = "6" } })
        end
        local local_path = tempPath("ltn12.bin")
        local okd, derr = client:download("书库/x.txt", local_path)
        eq(derr, nil)
        eq(okd, true)
        local fh = io.open(local_path, "rb")
        local content = fh:read("*all")
        fh:close()
        eq(content, "abcdef")
        os.remove(local_path)

        -- upload：ltn12.source.file 上传
        local up_path = tempPath("ltn12-up.bin")
        local wf = io.open(up_path, "wb")
        wf:write("payload")
        wf:close()
        FakeHttp.reset()
        local got = nil
        FakeHttp.handler = function(req)
            got = drainSource(req.source)
            return respond(req, 201)
        end
        local oku, uerr = client:upload(up_path, "书库/up.bin")
        eq(uerr, nil)
        eq(oku, true)
        eq(got, "payload")
        os.remove(up_path)
    end)
    useFallbackDeps()
    if not okrun then error(err) end
end)

test("兜底与 KOReader 实现在同一批用例上结果一致", function()
    local samples = {
        { "书库/三体 1.txt", "" },
        { "a b/c%d.epub", "" },
        { "a?b&c=d#e", "" },
        { "-._~AZaz09", "" },
        { "书库/", "" },
        { "", "" },
    }
    local results_fallback, results_koreader = {}, {}
    useFallbackDeps()
    for i, s in ipairs(samples) do
        results_fallback[i] = WebDAV.joinUrl("https://h/dav", s[1], { trailing_slash = (i % 2 == 0) })
    end
    useKoreaderDeps()
    for i, s in ipairs(samples) do
        results_koreader[i] = WebDAV.joinUrl("https://h/dav", s[1], { trailing_slash = (i % 2 == 0) })
    end
    useFallbackDeps()
    for i = 1, #samples do
        eq(results_koreader[i], results_fallback[i],
            "第 " .. i .. " 个样本：" .. samples[i][1] .. " 的编码结果应一致")
    end
end)

-- ---------------------------------------------------------------------------
-- 9. gettext 集成（防回归：模块内的 _ 不能被局部占位变量遮蔽）
-- ---------------------------------------------------------------------------

test("gettext 若可用则被用于错误文案", function()
    -- 装一个假的 gettext：把文案包成 [xx] 以便断言「确实走了 gettext」
    local calls = 0
    local fakeGettext = function(s)
        calls = calls + 1
        return "[" .. s .. "]"
    end
    package.loaded["gettext"] = fakeGettext

    -- 重新加载模块，使其在初始化阶段捕获 fake gettext
    package.loaded["wdr.webdav"] = nil
    local FreshWebDAV = require("wdr.webdav")
    FreshWebDAV.setDependencies({
        http = FakeHttp,
        socketutil = FakeSocketutil,
    })
    eq(calls, 0, "_() 应延迟到真正出错时才调用，不在模块加载期取文案")

    -- 触发一条错误文案，确认它被翻译（而不是被局部 _ 遮蔽成 table/报错）
    FakeHttp.reset()
    FakeHttp.handler = function(req) return respond(req, 401) end
    local client = FreshWebDAV.client({ address = "" })
    local items, err = client:list("")
    eq(items, nil)
    ok(calls > 0, "配置错误文案应该经过 gettext")
    contains(err, "[Server address is not configured]",
        "错误文案应被 gettext 处理（说明模块内的 _ 未被局部变量遮蔽）")

    -- 传输层错误同样经过 gettext
    FakeHttp.reset()
    FakeHttp.handler = function() return nil, "timeout" end
    local c2 = FreshWebDAV.client({ address = "https://example.com/dav" })
    local items2, err2 = c2:list("")
    eq(items2, nil)
    contains(err2, "timed out")
    contains(err2, "[", "传输层错误文案也应经过 gettext（带方括号）")

    -- 恢复
    package.loaded["gettext"] = nil
    package.loaded["wdr.webdav"] = nil
    WebDAV = require("wdr.webdav")
end)

-- ---------------------------------------------------------------------------
-- 10. DAV:creationdate 解析（created 字段，供「创建时间」排序使用）
-- ---------------------------------------------------------------------------

-- Nextcloud / SabreDAV 都会在 creationdate 里给 RFC 3339（带 Z 或时区偏移），
-- 但服务器也完全可能不返回它，或者返回一个非标准值 —— 两种情况都不能让解析崩，
-- 也都**不允许**用 getlastmodified 冒充（created 缺失必须保持 nil，排序时才好在最后）。
local CREATED_XML = [[<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response>
  <d:href>/dav/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/z.txt</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype/>
    <d:getcontentlength>10</d:getcontentlength>
    <d:creationdate>2024-11-12T09:30:15Z</d:creationdate>
    <d:getlastmodified>Tue, 12 Nov 2024 10:00:00 GMT</d:getlastmodified>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/y.txt</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype/>
    <d:getcontentlength>20</d:getcontentlength>
    <d:creationdate>2024-11-12T17:30:15+08:00</d:creationdate>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/x.txt</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype/>
    <d:getcontentlength>30</d:getcontentlength>
    <d:getlastmodified>Tue, 12 Nov 2024 11:00:00 GMT</d:getlastmodified>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/broken.txt</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype/>
    <d:creationdate>不是时间</d:creationdate>
    <d:getlastmodified>Tue, 12 Nov 2024 12:00:00 GMT</d:getlastmodified>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/empty.txt</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype/>
    <d:creationdate></d:creationdate>
    <d:getlastmodified>Tue, 12 Nov 2024 13:00:00 GMT</d:getlastmodified>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/dav/sub/</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
    <d:creationdate>2024-01-02T03:04:05Z</d:creationdate>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
</d:multistatus>]]

test("parseMultiStatus：creationdate 带 Z 的 RFC3339 解析成 created", function()
    local items, err = WebDAV.parseMultiStatus(CREATED_XML, {
        address = "https://example.com/dav",
        self_path = "",
    })
    eq(err, nil)
    eq(#items, 6, "应有 6 个子项（目录自身被剔除）")
    eq(items[1].name, "z.txt")
    eq(items[1].created, 1731403815, "2024-11-12T09:30:15Z 应换算成 unix 秒")
    eq(items[1].modified, 1731405600, "modified 与 created 各自独立解析")
end)

test("parseMultiStatus：creationdate 带 +08:00 偏移换算成 UTC", function()
    local items = WebDAV.parseMultiStatus(CREATED_XML, {
        address = "https://example.com/dav",
        self_path = "",
    })
    local y = items[2]
    eq(y.name, "y.txt")
    eq(y.created, 1731403815, "17:30:15+08:00 与 09:30:15Z 是同一时刻")
    eq(y.modified, nil, "该条目没有 getlastmodified，modified 应为 nil")
end)

test("parseMultiStatus：缺 creationdate 时 created 为 nil，不用 modified 冒充", function()
    local items = WebDAV.parseMultiStatus(CREATED_XML, {
        address = "https://example.com/dav",
        self_path = "",
    })
    local x = items[3]
    eq(x.name, "x.txt")
    eq(x.created, nil, "服务器没给 creationdate 就不能编一个")
    eq(x.modified, 1731409200, "modified 照常解析")
end)

test("parseMultiStatus：非法 / 空 creationdate 一律为 nil", function()
    local items = WebDAV.parseMultiStatus(CREATED_XML, {
        address = "https://example.com/dav",
        self_path = "",
    })
    local broken = items[4]
    eq(broken.name, "broken.txt")
    eq(broken.created, nil, "非时间文本应解析为 nil 而不是崩溃")
    eq(broken.modified, 1731412800, "同一条目的 modified 仍正常")

    local empty = items[5]
    eq(empty.name, "empty.txt")
    eq(empty.created, nil, "空元素 creationdate 应为 nil")
    eq(empty.modified, 1731416400)
end)

test("parseMultiStatus：目录条目也解析 created", function()
    local items = WebDAV.parseMultiStatus(CREATED_XML, {
        address = "https://example.com/dav",
        self_path = "",
    })
    local sub = items[6]
    eq(sub.name, "sub")
    eq(sub.is_folder, true, "目录条目同样带 created")
    ok(sub.created ~= nil, "目录应有 created")
    eq(sub.created, 1704164645, "2024-01-02T03:04:05Z")
end)

test("parseMultiStatus：没有 creationdate 字段的旧响应.created 全为 nil", function()
    -- NC_XML 是既有样本，一个 creationdate 都没有
    local items, err = WebDAV.parseMultiStatus(NC_XML, {
        address = "https://cloud.example.com/remote.php/dav/files/riko",
        self_path = "书库",
    })
    eq(err, nil)
    eq(#items, 2)
    eq(items[1].created, nil, "缺失时必须是 nil")
    eq(items[2].created, nil)
    ok(items[1].modified ~= nil, "但 modified 不受影响")
end)

test("client:list 的 PROPFIND 请求体包含 creationdate", function()
    FakeHttp.reset()
    local sent = nil
    FakeHttp.handler = function(req)
        sent = drainSource(req.source) or ""
        return respond(req, 207, { body = [[<d:multistatus xmlns:d="DAV:"></d:multistatus>]] })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(err, nil)
    ok(items ~= nil)
    ok(sent:find("creationdate", 1, true) ~= nil, "应请求 DAV:creationdate")
    ok(sent:find("getlastmodified", 1, true) ~= nil, "原有的 getlastmodified 不能被挤掉")
    ok(sent:find("resourcetype", 1, true) ~= nil)
    ok(sent:find("getcontentlength", 1, true) ~= nil)
end)

test("client:list 能带回 created 字段", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        return respond(req, 207, { body = CREATED_XML })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(err, nil)
    eq(#items, 6)
    eq(items[1].name, "z.txt")
    eq(items[1].created, 1731403815, "created 应一路带到 client:list 的返回值里")
    eq(items[3].created, nil, "缺值项保持 nil")
end)

-- ---------------------------------------------------------------------------
-- creationdate 的降级重试（严格服务器拒绝未知属性时不能连累目录浏览）
-- ---------------------------------------------------------------------------

--- 模拟「不认识 creationdate 就整体报错」的严格服务器：
-- 请求体含 creationdate 时返回指定错误码，否则正常返回 207。
-- 同时把每次请求体记录到 level_bodies，便于断言「首次带 / 重试不带」。
local level_bodies = {}
local function strictServer(err_code, xml)
    return function(req)
        local sent = drainSource(req.source) or ""
        level_bodies[#level_bodies + 1] = sent
        if sent:find("creationdate", 1, true) then
            return respond(req, err_code, { status = "HTTP/1.1 " .. err_code .. " Error" })
        end
        return respond(req, 207, { body = xml or [[<d:multistatus xmlns:d="DAV:"></d:multistatus>]] })
    end
end

test("client:list 服务器拒绝 creationdate 时自动降级重试（400）", function()
    FakeHttp.reset()
    level_bodies = {}
    FakeHttp.handler = strictServer(400)
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(err, nil, "降级后应成功，不应把错误抛给界面")
    ok(items ~= nil, "应返回列表")
    eq(#FakeHttp.requests, 2, "应发生两次请求（带 creationdate + 基础体）")
    -- 注意：handler 内部已经把 source 读空，这里改为回看 handler 记录的请求体
    eq(level_bodies[2] and level_bodies[2]:find("creationdate", 1, true), nil,
        "重试请求体不应再包含 creationdate")
    ok(level_bodies[2] and level_bodies[2]:find("getlastmodified", 1, true) ~= nil,
        "重试仍要请求基础属性")
    ok(level_bodies[1] and level_bodies[1]:find("creationdate", 1, true) ~= nil,
        "首次请求体应包含 creationdate")
end)

test("client:list 降级对各种拒绝码都生效（403/409/500）", function()
    for _, code in ipairs({ 403, 409, 500 }) do
        FakeHttp.reset()
        FakeHttp.handler = strictServer(code)
        local client = WebDAV.client(SERVER)
        local items, err = client:list("")
        eq(err, nil, "状态码 " .. code .. " 时应降级成功")
        ok(items ~= nil, "状态码 " .. code .. " 时应返回列表")
        eq(#FakeHttp.requests, 2, "状态码 " .. code .. " 时应重试一次")
    end
end)

test("client:list 降级后记住该服务器，后续不再重复试探", function()
    FakeHttp.reset()
    FakeHttp.handler = strictServer(400)
    local client = WebDAV.client(SERVER)
    client:list("")
    eq(#FakeHttp.requests, 2, "首次：先试探再降级")

    FakeHttp.requests = {}
    FakeHttp.handler = function(req)
        local sent = drainSource(req.source) or ""
        eq(sent:find("creationdate", 1, true), nil, "后续请求不应再带 creationdate")
        return respond(req, 207, { body = [[<d:multistatus xmlns:d="DAV:"></d:multistatus>]] })
    end
    client:list("books")
    eq(#FakeHttp.requests, 1, "第二次只需一次请求")
end)

test("client:list 降级只对「带 creationdate 失败」生效，真错误仍要报出", function()
    FakeHttp.reset()
    -- 两种体都报 500：说明不是 creationdate 的问题，应把错误报给调用方
    FakeHttp.handler = function(req)
        drainSource(req.source)
        return respond(req, 500, { status = "HTTP/1.1 500 Internal Server Error" })
    end
    local client = WebDAV.client(SERVER)
    local items, err = client:list("")
    eq(items, nil, "应返回 nil")
    ok(err ~= nil, "应返回错误")
    contains(err, "500", "错误里应带状态码")
    eq(#FakeHttp.requests, 2, "仍会重试一次（无法预知是否属性问题）")
end)

test("client:exists 也能容忍服务器拒绝 creationdate", function()
    FakeHttp.reset()
    FakeHttp.handler = strictServer(400, [[<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/dav/books/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>]])
    local client = WebDAV.client(SERVER)
    local exists, is_folder, err = client:exists("books")
    eq(err, nil, "降级后不该报错")
    eq(exists, true, "应判定存在")
    eq(is_folder, true, "应判定是目录")
end)

test("client:exists 的 404 不触发无谓重试", function()
    FakeHttp.reset()
    FakeHttp.handler = function(req)
        drainSource(req.source)
        return respond(req, 404, { status = "HTTP/1.1 404 Not Found" })
    end
    local client = WebDAV.client(SERVER)
    local exists, is_folder, err = client:exists("nope")
    eq(err, nil)
    eq(exists, false, "404 表示不存在")
    eq(#FakeHttp.requests, 1, "404 是有效答案，不该重试")
end)

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------

print("")
print(string.rep("-", 62))
if fail_count > 0 then
    print(string.format("失败用例：%d 个", #failures))
    for _, f in ipairs(failures) do
        print("  ✗ " .. f)
    end
end
print(string.format("结果：%d 通过, %d 失败, 共 %d 个断言",
    pass_count, fail_count, pass_count + fail_count))
print(string.rep("-", 62))

os.exit(fail_count == 0 and 0 or 1)
