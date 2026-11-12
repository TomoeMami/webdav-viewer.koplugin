-- @selfrun 自包含运行（内部 os.exit），由 run_all.lua 以子进程方式调用
--[[--
端到端集成测试：用真实 HTTP 打真实 WebDAV 服务器

启动测试服务器（在宿主机上，端口 18080，用户 user/secret，根 /tmp/wdav_root）：
    /tmp/wdvenv/bin/python /tmp/wdav_server.py

然后运行本测试：
    ./tools/lua tests/test_integration.lua

若服务器不可用，本套件自动 SKIP（退出码 0），避免 CI 环境误报。

验证的真实链路：
    browser 的数据准备 -> webdav.list -> webdav.download
    -> progress 保存（按远程路径为键）
    -> manager 删除/移动/新建目录
    -> 清缓存后进度仍可读

@module tests.test_integration
--]]--

package.path = table.concat({
    "webdavreader.koplugin/?.lua",
    "tests/?.lua",
    package.path,
}, ";")
package.cpath = table.concat({
    "tools/?.so",
    "tools/luasocket/?.so",
    "tools/luasocket/?/?.so",
    package.cpath,
}, ";")
package.path = "tools/luasocket/lua/?.lua;" .. package.path

require("stubs").install()

-- ---------------------------------------------------------------------------
-- 测试框架
-- ---------------------------------------------------------------------------

local pass_count, fail_count = 0, 0
local failures = {}
local current_case = nil

local function ok(cond, msg)
    if cond then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] %s", current_case or "?", msg or "断言失败")
    end
    return cond
end

local function eq(actual, expected, msg)
    if actual == expected then
        pass_count = pass_count + 1
        return true
    end
    fail_count = fail_count + 1
    failures[#failures + 1] = string.format("[%s] %s\n      期望: %q\n      实际: %q",
        current_case or "?", msg or "值不相等", tostring(expected), tostring(actual))
    return false
end

local function contains(haystack, needle, msg)
    local cond = type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
    if not cond then
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] %s\n      期望包含: %q\n      实际: %q",
            current_case or "?", msg or "未包含", tostring(needle), tostring(haystack))
        return false
    end
    pass_count = pass_count + 1
    return true
end

local function case(name, fn)
    current_case = name
    local okk, err = pcall(fn)
    if not okk then
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] 抛出异常: %s", name, tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- 环境准备
-- ---------------------------------------------------------------------------

local HOST = os.getenv("WDR_TEST_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("WDR_TEST_PORT") or "18080")
local ADDRESS = string.format("http://%s:%d/dav", HOST, PORT)
local USER = os.getenv("WDR_TEST_USER") or "user"
local PASS = os.getenv("WDR_TEST_PASS") or "secret"

local WebDAV = require("wdr.webdav")
local Progress = require("wdr.progress")
local Cache = require("wdr.cache")
local Config = require("wdr.config")
local Manager = require("wdr.manager")
local Store = require("wdr.store")

local server = {
    name = "集成测试服务器",
    address = ADDRESS,
    username = USER,
    password = PASS,
    start_dir = "/",
}

local client, client_err = WebDAV.client(server)

-- 探测服务器是否可达
local reachable = false
if client then
    local items = client:list("")
    if items then reachable = true end
end

if not reachable then
    print("")
    print(string.rep("-", 62))
    print("SKIP：集成测试服务器不可达（" .. tostring(client_err or "list 失败") .. "）")
    print("      启动方式：/tmp/wdvenv/bin/python /tmp/wdav_server.py")
    print(string.rep("-", 62))
    os.exit(0)
end

print("")
print("集成测试目标：" .. ADDRESS)

local test_dir = "/tmp/wdr_integration"
os.execute("rm -rf '" .. test_dir .. "'")
os.execute("mkdir -p '" .. test_dir .. "'")

Progress:init(test_dir .. "/progress.json")
Cache:setDir(test_dir .. "/cache")
Cache:ensureDir()

local client_factory = function(srv) return client end
Manager:setup{ config = Config, progress = Progress, cache = Cache, get_client = client_factory }

-- ---------------------------------------------------------------------------
-- 用例
-- ---------------------------------------------------------------------------

case("list 根目录", function()
    local items = client:list("")
    ok(items, "应返回列表")
    ok(#items >= 2, "根目录至少 2 项，实际 " .. tostring(#items and #items or -1))
end)

case("list 子目录，文件名正确解码（含中文）", function()
    local items = client:list("books")
    ok(items, "应返回列表")
    local names = {}
    for _, it in ipairs(items) do names[it.name] = it end
    ok(names["三体.txt"], "应包含中文文件名的文件")
    ok(names["readme.md"], "应包含 readme.md")
    ok(not names["books"], "不应包含目录自身")
    eq(names["三体.txt"].is_folder, false, "文件不应被标记为目录")
    ok((names["三体.txt"].size or 0) > 0, "应能取到文件大小")
    ok(names["三体.txt"].modified, "应能取到修改时间")
end)

case("list 根级子目录被识别为目录", function()
    local items = client:list("")
    local found = false
    for _, it in ipairs(items) do
        if it.name == "books" then
            found = true
            eq(it.is_folder, true, "books 应是目录")
        end
    end
    ok(found, "根目录应列出 books")
end)

case("list 含空格与中文的目录", function()
    local items = client:list("notes")
    ok(items, "应返回列表")
    local found = false
    for _, it in ipairs(items) do
        if it.name == "中文 文件.txt" then found = true end
    end
    ok(found, "应能正确解码带空格的 UTF-8 文件名")
end)

case("list 不存在的目录返回错误而非崩溃", function()
    local items, err = client:list("does_not_exist_xyz")
    eq(items, nil, "应返回 nil")
    ok(err, "应返回错误信息")
end)

case("download 下载中文名文件到缓存", function()
    local local_path = Cache:getLocalPath(server, "books/三体.txt")
    ok(local_path, "应能生成缓存路径")
    local okk, err = client:download("books/三体.txt", local_path)
    ok(okk, "下载应成功：" .. tostring(err))
    local fh = io.open(local_path, "r")
    ok(fh, "本地文件应存在")
    local content = fh:read("*all")
    fh:close()
    contains(content, "第1行", "内容应正确")
    contains(content, "第200行", "应下载完整内容")
end)

case("download 后缓存新鲜度判定", function()
    local items = client:list("books")
    local size
    for _, it in ipairs(items) do
        if it.name == "三体.txt" then size = it.size end
    end
    ok(size, "应取到远端大小")
    eq(Cache:isFresh(server, "books/三体.txt", size), true, "大小一致应判定为新鲜")
    eq(Cache:isFresh(server, "books/三体.txt", size + 1), false, "大小不符应判定为不新鲜")
end)

case("download 不存在的文件返回错误且不留半截文件", function()
    local local_path = Cache:getLocalPath(server, "books/nonexistent.txt")
    local okk, err = client:download("books/nonexistent.txt", local_path)
    ok(not okk, "应失败（返回 falsy）")
    ok(err, "应有错误信息")
    local lfs = require("lfs")
    eq(lfs.attributes(local_path, "mode"), nil, "不应残留半截文件")
end)

case("进度按远程路径保存并可读回", function()
    Progress:save(server, "books/三体.txt", { percent = 0.37, page = 74, total_pages = 200 })
    local e = Progress:get(server, "books/三体.txt")
    ok(e, "应读到进度")
    eq(e.percent, 0.37, "百分比应一致")
    eq(e.page, 74, "页码应一致")
    eq(e.remote_path, "books/三体.txt", "应记录远程路径")
    eq(e.title, "三体.txt", "应记录文件名")
end)

case("同名不同目录的进度互不干扰（真实中文文件）", function()
    Progress:save(server, "books/三体.txt", { percent = 0.11 })
    Progress:save(server, "notes/三体.txt", { percent = 0.88 })
    eq(Progress:get(server, "books/三体.txt").percent, 0.11, "books 下的应保持")
    eq(Progress:get(server, "notes/三体.txt").percent, 0.88, "notes 下的应是另一个值")
    Progress:remove(server, "notes/三体.txt")
end)

case("清空缓存后进度依然存在（本插件核心需求）", function()
    local e_before = Progress:get(server, "books/三体.txt")
    ok(e_before, "清空前应有进度")

    local cache_name_before = Store.getCacheFileName(server, "books/三体.txt")
    Cache:clear()

    local lfs = require("lfs")
    eq(lfs.attributes(Cache:getLocalPath(server, "books/三体.txt"), "mode"), nil,
        "缓存文件应已被删除")

    local e_after = Progress:get(server, "books/三体.txt")
    ok(e_after, "清缓存后进度仍应存在")
    eq(e_after.percent, e_before.percent, "百分比应保持")
    eq(Store.getCacheFileName(server, "books/三体.txt"), cache_name_before,
        "缓存名应稳定，便于下次直接复用")
end)

case("进度落盘为 JSON 且可重新加载", function()
    Progress:flush()
    local fh = io.open(test_dir .. "/progress.json", "r")
    ok(fh, "进度文件应存在")
    local content = fh:read("*all")
    fh:close()
    contains(content, "\"version\":1", "应是约定的 JSON 结构")
    contains(content, "books/三体.txt", "应包含远程路径键")

    -- 全新实例重新加载
    local Progress2 = dofile and require("wdr.progress")
    local json = require("wdr.json")
    local decoded, err = json.decode(content)
    eq(err, nil, "应是合法 JSON")
    local key = Store.getRemoteKey(server, "books/三体.txt")
    ok(decoded.files[key], "应含该远程键")
end)

case("mkdir 新建目录", function()
    -- 清理上次运行可能残留的目录，保证用例可重复执行
    if client:exists("_test_mkdir") then client:delete("_test_mkdir") end
    local okk, new_path, err = Manager:createFolder(server, "", "_test_mkdir")
    ok(okk, "新建目录应成功：" .. tostring(err))
    eq(new_path, "_test_mkdir", "返回新路径")
    local items = client:list("")
    local found = false
    for _, it in ipairs(items) do
        if it.name == "_test_mkdir" and it.is_folder then found = true end
    end
    ok(found, "目录应出现在列表中")
end)

case("mkdir 重名目录报错而非静默成功", function()
    local okk, _, err = Manager:createFolder(server, "", "_test_mkdir")
    eq(okk, false, "已存在的目录应失败")
    ok(err, "应有错误信息")
end)

case("upload 后用 list 能看到，download 得到一致内容", function()
    local tmp = test_dir .. "/upload.txt"
    local fh = io.open(tmp, "w")
    fh:write("上传内容 line1\nline2\n")
    fh:close()

    local okk, err = client:upload(tmp, "_test_mkdir/uploaded.txt")
    ok(okk, "上传应成功：" .. tostring(err))

    local items = client:list("_test_mkdir")
    ok(items, "应能列出")
    local found = false
    for _, it in ipairs(items) do
        if it.name == "uploaded.txt" then found = true end
    end
    ok(found, "上传的文件应出现")

    local back = test_dir .. "/download_check.txt"
    local ok2 = client:download("_test_mkdir/uploaded.txt", back)
    ok(ok2, "下载应成功")
    local rf = io.open(back, "r")
    local content = rf:read("*all")
    rf:close()
    eq(content, "上传内容 line1\nline2\n", "内容应往返一致")
end)

case("move 移动文件后进度跟随迁移", function()
    Progress:save(server, "_test_mkdir/uploaded.txt", { percent = 0.5, page = 1 })
    local okk, err = Manager:moveItem(server, "_test_mkdir/uploaded.txt", "_test_mkdir/moved.txt")
    ok(okk, "移动应成功：" .. tostring(err))

    local items = client:list("_test_mkdir")
    local names = {}
    for _, it in ipairs(items) do names[it.name] = it end
    ok(names["moved.txt"], "新名字应存在")
    eq(names["uploaded.txt"], nil, "旧名字应不存在")

    eq(Progress:get(server, "_test_mkdir/uploaded.txt"), nil, "旧路径进度应被清空")
    local e = Progress:get(server, "_test_mkdir/moved.txt")
    ok(e, "新路径应有进度")
    eq(e.percent, 0.5, "进度值应保留")
end)

case("renameFile 改名", function()
    local okk, new_path, err = Manager:renameFile(server, "_test_mkdir/moved.txt", "renamed.txt")
    ok(okk, "改名应成功：" .. tostring(err))
    eq(new_path, "_test_mkdir/renamed.txt", "应返回新路径")

    local items = client:list("_test_mkdir")
    local names = {}
    for _, it in ipairs(items) do names[it.name] = it end
    ok(names["renamed.txt"], "新名字应存在")
    eq(Progress:get(server, "_test_mkdir/renamed.txt") ~= nil, true, "进度应迁到新键")
end)

case("renameFile 拒绝非法名字", function()
    local okk, _, err = Manager:renameFile(server, "_test_mkdir/renamed.txt", "bad/name.txt")
    eq(okk, false, "含斜杠的名字应被拒绝")
    ok(err, "应有错误信息")
end)

case("deleteFile 删除文件并清理进度", function()
    local okk, err = Manager:deleteFile(server, "_test_mkdir/renamed.txt")
    ok(okk, "删除应成功：" .. tostring(err))

    local items = client:list("_test_mkdir")
    for _, it in ipairs(items) do
        ok(it.name ~= "renamed.txt", "文件应已被删除")
    end
    eq(Progress:get(server, "_test_mkdir/renamed.txt"), nil, "进度应被清理")
end)

case("deleteFolder 递归删除（含子目录与文件）", function()
    -- 造一个嵌套结构
    local ok1 = client:mkdir("_test_del")
    ok(ok1, "建顶层目录")
    local ok2 = client:mkdir("_test_del/sub")
    ok(ok2, "建子目录")
    local f = test_dir .. "/del.txt"
    local fh = io.open(f, "w") fh:write("x") fh:close()
    client:upload(f, "_test_del/a.txt")
    client:upload(f, "_test_del/sub/b.txt")
    Progress:save(server, "_test_del/a.txt", { percent = 0.1 })
    Progress:save(server, "_test_del/sub/b.txt", { percent = 0.2 })

    local files, folders = Manager:countFolderItems(server, "_test_del")
    eq(files, 2, "应统计到 2 个文件")
    eq(folders, 1, "应统计到 1 个子目录")

    local okk, count, err = Manager:deleteFolder(server, "_test_del")
    ok(okk, "递归删除应成功：" .. tostring(err))
    ok(count and count >= 3, "应删除至少 3 项，实际 " .. tostring(count))

    local items = client:list("")
    for _, it in ipairs(items) do
        ok(it.name ~= "_test_del", "目录应已消失")
    end
    eq(Progress:get(server, "_test_del/a.txt"), nil, "子文件进度应清理")
    eq(Progress:get(server, "_test_del/sub/b.txt"), nil, "深层文件进度应清理")
end)

case("deleteFolder 拒绝删除服务器根", function()
    local okk, _, err = Manager:deleteFolder(server, "")
    eq(okk, false, "不应允许删根目录")
    ok(err, "应有错误信息")
end)

case("不存在的文件删除返回错误", function()
    local okk, err = Manager:deleteFile(server, "no_such_file_abc.txt")
    eq(okk, false, "应失败")
    ok(err, "应有错误信息")
end)

case("认证失败返回可读错误", function()
    local bad, _ = WebDAV.client({
        address = ADDRESS, username = "user", password = "wrong_password",
    })
    ok(bad, "客户端应能创建")
    local items, err = bad:list("")
    eq(items, nil, "应失败")
    ok(err, "应有错误信息")
    contains(tostring(err), "401", "应包含 401 状态码")
end)

case("地址错误返回可读错误", function()
    local bad = WebDAV.client({ address = "http://127.0.0.1:1/dav" })
    ok(bad, "客户端应能创建")
    local items, err = bad:list("")
    eq(items, nil, "应失败")
    ok(err, "应有错误信息")
end)

case("缓存清理不影响远程文件", function()
    Cache:clear()
    local items = client:list("books")
    ok(items and #items >= 2, "远程文件应完好")
end)

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------

os.execute("rm -rf '" .. test_dir .. "'")

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
