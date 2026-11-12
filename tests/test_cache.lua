--[[--
wdr/cache.lua 单元测试
--]]--

local M = {}

function M.run(T, root)
    local Cache = require("wdr.cache")
    local Store = require("wdr.store")
    local lfs = require("lfs")

    io.write("\n### cache\n")

    local server = { name = "NAS", address = "https://nas.example.com/dav" }
    local function freshDir(name)
        local dir = root .. "/tmp_cache/" .. (name or "default")
        os.execute("rm -rf '" .. dir .. "'")
        Cache:setDir(dir)
        Cache.access_times = {}
        Cache:ensureDir()
        return dir
    end

    local function writeFile(path, content)
        local fh = io.open(path, "w")
        if not fh then error("无法写文件 " .. path) end
        fh:write(content)
        fh:close()
    end

    T.test("ensureDir 创建目录", function()
        local dir = freshDir("ensure")
        T.eq(lfs.attributes(dir, "mode"), "directory")
        -- 幂等
        T.eq(Cache:ensureDir(), true)
    end)

    T.test("getLocalPath 生成唯一路径", function()
        freshDir("paths")
        local p1 = Cache:getLocalPath(server, "/books/a.txt")
        local p2 = Cache:getLocalPath(server, "/other/a.txt")
        T.ok(p1 ~= p2, "同名不同目录应不同路径")
        T.contains(p1, ".txt")
        T.contains(p1, "/tmp_cache/paths/")
    end)

    T.test("getLocalPath 无目录时返回 nil", function()
        Cache:setDir(nil)
        T.eq(Cache:getLocalPath(server, "/a.txt"), nil)
    end)

    T.test("isFresh 判断文件大小一致", function()
        freshDir("fresh")
        local p = Cache:getLocalPath(server, "/books/a.txt")
        writeFile(p, "12345")
        T.eq(Cache:isFresh(server, "/books/a.txt", 5), true)
        T.eq(Cache:isFresh(server, "/books/a.txt", 6), false, "大小不符应视为不新鲜")
    end)

    T.test("isFresh 对不存在的文件返回 false", function()
        freshDir("fresh2")
        T.eq(Cache:isFresh(server, "/nope.txt", 5), false)
    end)

    T.test("isFresh 远端无大小时按存在判断", function()
        freshDir("fresh3")
        local p = Cache:getLocalPath(server, "/b.txt")
        T.eq(Cache:isFresh(server, "/b.txt", nil), false, "不存在时")
        writeFile(p, "x")
        T.eq(Cache:isFresh(server, "/b.txt", nil), true, "存在时")
    end)

    T.test("exists 判断本地文件", function()
        freshDir("exists")
        T.eq(Cache:exists(server, "/x.txt"), false)
        writeFile(Cache:getLocalPath(server, "/x.txt"), "data")
        T.eq(Cache:exists(server, "/x.txt"), true)
    end)

    T.test("invalidate 删除本地副本", function()
        freshDir("invalidate")
        local p = Cache:getLocalPath(server, "/x.txt")
        writeFile(p, "data")
        Cache:invalidate(server, "/x.txt")
        T.eq(lfs.attributes(p, "mode"), nil)
    end)

    T.test("invalidate 同时清理 sidecar 目录", function()
        freshDir("sidecar")
        local p = Cache:getLocalPath(server, "/x.epub")
        writeFile(p, "data")
        lfs.mkdir(p .. ".sdr")
        writeFile(p .. ".sdr/metadata.lua", "return {}")
        Cache:invalidate(server, "/x.epub")
        T.eq(lfs.attributes(p .. ".sdr", "mode"), nil, "sidecar 应被清理")
    end)

    T.test("invalidate 对不存在的文件安全", function()
        freshDir("invalidate2")
        Cache:invalidate(server, "/nope.txt") -- 不应报错
        T.ok(true)
    end)

    T.test("sizeBytes 统计总大小", function()
        local dir = freshDir("size")
        writeFile(dir .. "/a.txt", "12345")
        writeFile(dir .. "/b.txt", "1234567890")
        T.eq(Cache:sizeBytes(), 15)
    end)

    T.test("sizeBytes 空目录为 0", function()
        freshDir("size2")
        T.eq(Cache:sizeBytes(), 0)
    end)

    T.test("listEntries 列出文件及元信息", function()
        local dir = freshDir("list")
        writeFile(dir .. "/a.txt", "12345")
        writeFile(dir .. "/b.txt", "67")
        local entries = Cache:listEntries()
        T.eq(#entries, 2)
        local names = {}
        for _, e in ipairs(entries) do names[e.name] = e end
        T.eq(names["a.txt"].size, 5)
        T.eq(names["b.txt"].size, 2)
        T.ok(names["a.txt"].mtime > 0)
    end)

    T.test("prune 超限时淘汰旧文件", function()
        local dir = freshDir("prune")
        -- 造一个 2MB 的文件
        local big = dir .. "/big.bin"
        local fh = io.open(big, "w")
        fh:write(string.rep("x", 2 * 1024 * 1024))
        fh:close()
        -- 设置很旧的 mtime
        os.execute(string.format("touch -d '2020-01-01' '%s'", big))

        T.eq(Cache:sizeBytes(), 2 * 1024 * 1024)
        local freed = Cache:prune(1) -- 上限 1MB
        T.eq(freed, 2 * 1024 * 1024, "应释放整个文件")
        T.eq(lfs.attributes(big, "mode"), nil)
    end)

    T.test("prune 未超限不删", function()
        local dir = freshDir("prune2")
        writeFile(dir .. "/small.txt", "12345")
        local freed = Cache:prune(100)
        T.eq(freed, 0)
        T.eq(lfs.attributes(dir .. "/small.txt", "mode"), "file")
    end)

    T.test("prune 保护最近访问的文件", function()
        local dir = freshDir("prune3")
        local p = dir .. "/recent.bin"
        local fh = io.open(p, "w")
        fh:write(string.rep("x", 1024 * 1024))
        fh:close()
        os.execute(string.format("touch -d '2020-01-01' '%s'", p))
        -- 标记为刚访问
        Cache.access_times[p] = os.time()
        Cache:prune(0.5) -- 上限 0.5MB，但文件受保护
        T.eq(lfs.attributes(p, "mode"), "file", "刚访问的文件不应被删")
    end)

    T.test("clear 清空所有内容", function()
        local dir = freshDir("clear")
        writeFile(dir .. "/a.txt", "12345")
        lfs.mkdir(dir .. "/sub")
        writeFile(dir .. "/sub/b.txt", "67")
        local ok, freed = Cache:clear()
        T.eq(ok, true)
        T.eq(freed, 7)
        T.eq(#Cache:listEntries(), 0)
        T.eq(lfs.attributes(dir, "mode"), "directory", "目录本身应保留")
    end)

    T.test("clear 对不存在的目录安全", function()
        Cache:setDir(root .. "/tmp_cache/never_exists")
        local ok = Cache:clear()
        T.eq(ok, true)
    end)

    T.test("缓存名与进度键解耦：清缓存不影响进度", function()
        -- 说明性用例：确认缓存路径与进度键来自不同的纯函数
        local cache_name = Store.getCacheFileName(server, "/books/a.txt")
        local key = Store.getRemoteKey(server, "/books/a.txt")
        T.ok(cache_name ~= key)
        T.contains(key, "books/a.txt")
        -- 清缓存后再算一次，缓存名与键盘值都稳定
        T.eq(Store.getCacheFileName(server, "/books/a.txt"), cache_name)
        T.eq(Store.getRemoteKey(server, "/books/a.txt"), key)
    end)

    T.test("touch 记录访问时间", function()
        freshDir("touch")
        local p = Cache:getLocalPath(server, "/t.txt")
        writeFile(p, "x")
        Cache:touch(server, "/t.txt")
        T.ok(Cache.access_times[p], "应记录访问时间")
    end)

    return M
end

return M
