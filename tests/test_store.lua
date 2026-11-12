--[[--
wdr/store.lua 单元测试
--]]--

local M = {}

function M.run(T)
    local Store = require("wdr.store")
    local json = require("wdr.json")

    io.write("\n### store\n")

    local server_a = { name = "NAS A", address = "https://nas.example.com/dav" }
    local server_b = { name = "NAS B", address = "https://other.example.com/dav" }

    -- ---------------- 路径键 ----------------

    T.test("服务器 id 稳定且区分不同地址", function()
        local ida1 = Store.getServerId(server_a)
        local ida2 = Store.getServerId(server_a)
        T.eq(ida1, ida2, "同一地址两次结果一致")
        T.eq(#ida1, 12, "id 长度 12")
        local idb = Store.getServerId(server_b)
        T.ok(ida1 ~= idb, "不同地址 id 不同")
    end)

    T.test("服务器改名字不影响 id", function()
        local renamed = { name = "改过名的 NAS", address = server_a.address }
        T.eq(Store.getServerId(renamed), Store.getServerId(server_a))
    end)

    T.test("normalizeDir 去掉多余斜杠", function()
        T.eq(Store.normalizeDir("/books/"), "books")
        T.eq(Store.normalizeDir("books/"), "books")
        T.eq(Store.normalizeDir("//books//sub//"), "books/sub")
        T.eq(Store.normalizeDir(""), "")
        T.eq(Store.normalizeDir(nil), "")
        T.eq(Store.normalizeDir("/"), "")
    end)

    T.test("远程键格式为 serverid/相对路径", function()
        local key = Store.getRemoteKey(server_a, "/books/三体.txt")
        local sid = Store.getServerId(server_a)
        T.eq(key, sid .. "/books/三体.txt")
    end)

    T.test("远程键对前导斜杠不敏感", function()
        T.eq(Store.getRemoteKey(server_a, "books/a.txt"),
             Store.getRemoteKey(server_a, "/books/a.txt"))
        T.eq(Store.getRemoteKey(server_a, "books/a.txt"),
             Store.getRemoteKey(server_a, "/books/a.txt/"))
    end)

    T.test("不同服务器同名路径键不同", function()
        T.ok(Store.getRemoteKey(server_a, "/books/a.txt")
             ~= Store.getRemoteKey(server_b, "/books/a.txt"),
             "不同服务器应产生不同键")
    end)

    T.test("splitRemoteKey 往返", function()
        local key = Store.getRemoteKey(server_a, "/books/a.txt")
        local sid, rel = Store.splitRemoteKey(key)
        T.eq(sid, Store.getServerId(server_a))
        T.eq(rel, "books/a.txt")
    end)

    T.test("提取文件名与目录", function()
        T.eq(Store.getRemoteFileName("books/a.txt"), "a.txt")
        T.eq(Store.getRemoteFileName("/a.txt"), "a.txt")
        T.eq(Store.getRemoteFileName("a.txt"), "a.txt")
        T.eq(Store.getRemoteDir("books/sub/a.txt"), "books/sub")
        T.eq(Store.getRemoteDir("a.txt"), "")
        T.eq(Store.getRemoteDir("/books/a.txt"), "books")
    end)

    T.test("拼接远程路径", function()
        T.eq(Store.joinRemotePath("books", "a.txt"), "books/a.txt")
        T.eq(Store.joinRemotePath("", "a.txt"), "a.txt")
        T.eq(Store.joinRemotePath(nil, "a.txt"), "a.txt")
        T.eq(Store.joinRemotePath("/books/", "/sub/"), "books/sub")
    end)

    T.test("缓存文件名保留扩展名且可区分", function()
        local n1 = Store.getCacheFileName(server_a, "/books/a.txt")
        local n2 = Store.getCacheFileName(server_a, "/other/a.txt")
        T.ok(n1 ~= n2, "同名不同目录应不同")
        T.contains(n1, ".txt", "保留扩展名")
        T.contains(n1, "a", "保留可读名")
    end)

    T.test("缓存文件名对中文与空格安全", function()
        local n = Store.getCacheFileName(server_a, "/books/三体 第一部.epub")
        T.contains(n, ".epub")
        T.ok(not n:find(" "), "不应含空格")
        T.ok(not n:find("/"), "不应含斜杠")
        T.ok(not n:find("三"), "非 ASCII 已替换")
    end)

    T.test("缓存文件名去重：不同扩展名", function()
        local a = Store.getCacheFileName(server_a, "/b/x.txt")
        local b = Store.getCacheFileName(server_a, "/b/x.md")
        T.ok(a ~= b)
        T.contains(a, ".txt")
        T.contains(b, ".md")
    end)

    T.test("缓存文件名超长截断", function()
        local longname = string.rep("abcdefghij", 20) .. ".txt"
        local n = Store.getCacheFileName(server_a, "/b/" .. longname)
        T.ok(#n < 120, "应被截断")
        T.contains(n, ".txt")
    end)

    T.test("缓存文件名对无扩展名文件", function()
        local n = Store.getCacheFileName(server_a, "/b/Makefile")
        T.ok(n and #n > 0)
    end)

    -- ---------------- 进度存储 ----------------

    local function memStore()
        local files = {}
        local writes = 0
        local store = Store.newProgressStore({
            path = "/virtual/progress.json",
            readfile = function(path) return files[path] end,
            writefile = function(path, content)
                files[path] = content
                writes = writes + 1
                return true
            end,
            encode = function(t) return json.encode(t) end,
            decode = function(s) return json.decode(s) end,
        })
        return store, files, function() return writes end
    end

    T.test("进度存储初始为空", function()
        local store = memStore()
        T.eq(store:get("a/b.txt"), nil)
        T.eq(#store:list(), 0)
    end)

    T.test("进度存储 set/get", function()
        local store = memStore()
        store:set("sid/books/a.txt", { percent = 0.5, page = 10 })
        local e = store:get("sid/books/a.txt")
        T.near(e.percent, 0.5)
        T.eq(e.page, 10)
        T.ok(e.updated, "应自动填 updated")
    end)

    T.test("进度存储 set 合并而非覆盖", function()
        local store = memStore()
        store:set("k", { percent = 0.5, page = 10 })
        store:set("k", { page = 20 })
        local e = store:get("k")
        T.near(e.percent, 0.5, nil, "旧字段应保留")
        T.eq(e.page, 20, "新字段应更新")
    end)

    T.test("进度存储 set 可附加元数据", function()
        local store = memStore()
        store:set("k", { percent = 0.1 }, {
            title = "三体.txt",
            server_name = "NAS",
            remote_path = "books/三体.txt",
        })
        local e = store:get("k")
        T.eq(e.title, "三体.txt")
        T.eq(e.server_name, "NAS")
        T.eq(e.remote_path, "books/三体.txt")
    end)

    T.test("进度存储 remove", function()
        local store = memStore()
        store:set("k", { percent = 0.5 })
        T.eq(store:remove("k"), true)
        T.eq(store:get("k"), nil)
        T.eq(store:remove("nonexistent"), false)
    end)

    T.test("进度存储 rename 迁移记录", function()
        local store = memStore()
        store:set("sid/old.txt", { percent = 0.7, page = 7 })
        T.eq(store:rename("sid/old.txt", "sid/sub/new.txt", { remote_path = "sub/new.txt" }), true)
        T.eq(store:get("sid/old.txt"), nil, "旧键应消失")
        local e = store:get("sid/sub/new.txt")
        T.near(e.percent, 0.7, nil, "进度应保留")
        T.eq(e.remote_path, "sub/new.txt")
    end)

    T.test("进度存储 rename 目标不存在时返回 false", function()
        local store = memStore()
        T.eq(store:rename("nope", "nope2"), false)
    end)

    T.test("进度存储 removeServer", function()
        local store = memStore()
        store:set("s1/a.txt", { percent = 0.1 })
        store:set("s1/b.txt", { percent = 0.2 })
        store:set("s2/c.txt", { percent = 0.3 })
        T.eq(store:removeServer("s1"), 2)
        T.eq(store:get("s1/a.txt"), nil)
        T.eq(store:get("s2/c.txt") ~= nil, true, "其他服务器不受影响")
    end)

    T.test("进度存储 list 按更新时间倒序", function()
        local store = memStore()
        store:set("a", { percent = 0.1, updated = 100 })
        store:set("b", { percent = 0.2, updated = 300 })
        store:set("c", { percent = 0.3, updated = 200 })
        local list = store:list()
        T.eq(#list, 3)
        T.eq(list[1].key, "b")
        T.eq(list[2].key, "c")
        T.eq(list[3].key, "a")
    end)

    T.test("进度存储 flush 落盘并可重新读取", function()
        local store, files = memStore()
        store:set("sid/a.txt", { percent = 0.42, xpointer = "/body/x" })
        T.eq(store:flush(), true)
        T.ok(files["/virtual/progress.json"], "文件应被写入")

        local store2 = Store.newProgressStore({
            path = "/virtual/progress.json",
            readfile = function(p) return files[p] end,
            writefile = function(p, c) files[p] = c return true end,
            encode = function(t) return json.encode(t) end,
            decode = function(s) return json.decode(s) end,
        })
        store2:load()
        local e = store2:get("sid/a.txt")
        T.near(e.percent, 0.42)
        T.eq(e.xpointer, "/body/x")
    end)

    T.test("flushIfDirty 无改动不写", function()
        local store, _, writes = memStore()
        store:set("a", { percent = 0.1 })
        store:flush()
        local before = writes()
        store:flushIfDirty()
        T.eq(writes(), before, "无改动不应重写")
        store:set("a", { percent = 0.2 })
        store:flushIfDirty()
        T.eq(writes(), before + 1, "有改动应写入")
    end)

    T.test("进度存储容忍损坏的 JSON", function()
        local corrupted = "{ this is not json"
        local backups = {}
        local store = Store.newProgressStore({
            path = "/p.json",
            readfile = function(p) return corrupted end,
            writefile = function(p, c) backups[p] = c return true end,
            encode = function(t) return json.encode(t) end,
            decode = function(s) return json.decode(s) end,
        })
        store:load()
        T.eq(#store:list(), 0, "损坏文件应从空表开始")
        -- 应产生备份文件
        local found_backup = false
        for p in pairs(backups) do
            if p:find("%.corrupt%-") then found_backup = true end
        end
        T.ok(found_backup, "损坏文件应被备份")
    end)

    T.test("进度存储空文件视为空表", function()
        local store = Store.newProgressStore({
            path = "/p.json",
            readfile = function() return "" end,
            writefile = function() return true end,
            encode = function(t) return json.encode(t) end,
            decode = function(s) return json.decode(s) end,
        })
        T.eq(store:load(), true)
        T.eq(#store:list(), 0)
    end)

    T.test("进度存储文件不存在视为空表", function()
        local store = Store.newProgressStore({
            path = "/p.json",
            readfile = function() return nil end,
            writefile = function() return true end,
            encode = function(t) return json.encode(t) end,
            decode = function(s) return json.decode(s) end,
        })
        T.eq(store:load(), true)
        T.eq(#store:list(), 0)
    end)

    T.test("进度存储无路径时 flush 失败但不崩溃", function()
        local store = Store.newProgressStore({})
        local ok, err = store:flush()
        T.eq(ok, false)
        T.ok(err)
    end)

    T.test("shortHash 对空串与非字符串安全", function()
        T.ok(#Store.shortHash("") > 0)
        T.ok(#Store.shortHash(nil) > 0)
    end)

    return M
end

return M
