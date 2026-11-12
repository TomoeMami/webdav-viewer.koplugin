--[[--
wdr/history.lua 单元测试（移动位置历史记录数据层）

覆盖：
  * add / list 的 MRU 顺序与 limit 截断
  * 同目录去重 + count 累加
  * 上限淘汰（DEFAULT_LIMIT）
  * 根目录 "" 是一条合法记录
  * 按服务器隔离（两个 server 互不可见）
  * remove / clear（含 clear 全部）
  * 落盘格式与往返（flush 后重新 load 读到同样内容）
  * 损坏 JSON 的兜底与 .corrupt- 备份
  * formatDir / formatLabel 文案
  * 未初始化时方法安全返回
--]]--

local M = {}

function M.run(T, root)
    local History = require("wdr.history")
    local Store = require("wdr.store")
    local Config = require("wdr.config")
    local json = require("wdr.json")

    io.write("\n### history\n")

    local server = { name = "NAS", address = "https://nas.example.com/dav" }
    local server2 = { name = "其他", address = "https://other.example.com/dav" }

    -- 内存文件系统：files[path] = content；writes 记录写次数
    local function memStore(opts)
        opts = opts or {}
        local files = opts.files or {}
        local writes = 0
        local store = Store.newJsonStore({
            path = opts.path or "/virtual/history.json",
            default_data = function() return { version = 1, servers = {} } end,
            readfile = function(p) return files[p] end,
            writefile = function(p, content)
                files[p] = content
                writes = writes + 1
                return true
            end,
            encode = function(t) return json.encode(t) end,
            decode = function(s)
                local decoded, err = json.decode(s)
                if err then error(err) end
                return decoded
            end,
        })
        return store, files, function() return writes end
    end

    -- 每个用例：全新的内存 store + 固定时钟（避免 os.time() 秒级粒度导致顺序不确定）
    local function freshHistory(clock_start)
        local store, files = memStore()
        History:_setStoreForTest(store, "/virtual/history.json")
        History:init("/virtual/history.json")
        local now = clock_start or 1000
        History:_setNowForTest(function()
            now = now + 1
            return now
        end)
        return store, files
    end

    -- ---------------- add / list 基本行为 ----------------

    T.test("初始为空数组", function()
        freshHistory()
        local list = History:list(server)
        T.is_table(list, "应返回 table 而不是 nil")
        T.eq(#list, 0)
        T.eq(History:getPath(), "/virtual/history.json")
    end)

    T.test("add 后 list 能读回记录", function()
        freshHistory()
        local ok, entry, err = History:add(server, "/books/done")
        T.eq(ok, true, "add 应成功")
        T.eq(err, nil)
        T.is_table(entry, "应返回归一化后的 entry")
        T.eq(entry.dir, "books/done", "前导斜杠应被去掉")
        T.eq(entry.count, 1)
        T.ok(entry.used > 0, "used 应是时间戳")

        local list = History:list(server)
        T.eq(#list, 1)
        T.eq(list[1].dir, "books/done")
        T.eq(list[1].count, 1)
    end)

    T.test("add 按 MRU 倒序（最近用的在最前）", function()
        freshHistory()
        History:add(server, "books")
        History:add(server, "papers")
        History:add(server, "archive")
        local list = History:list(server)
        T.eq(#list, 3)
        T.eq(list[1].dir, "archive", "最后一次 add 的应在最前")
        T.eq(list[2].dir, "papers")
        T.eq(list[3].dir, "books")
    end)

    T.test("同目录再次 add：不新增条目，count 累加并提到最前", function()
        freshHistory()
        History:add(server, "books")
        History:add(server, "papers")
        local ok, entry = History:add(server, "/books/")
        T.eq(ok, true)
        T.eq(entry.dir, "books", "路径归一化后应命中同一条")
        T.eq(entry.count, 2, "次数应累加")

        local list = History:list(server)
        T.eq(#list, 2, "不应新增条目")
        T.eq(list[1].dir, "books", "应被提到最前")
        T.eq(list[1].count, 2)
        T.eq(list[2].dir, "papers")
    end)

    T.test("同目录第三次 add 后 count 为 3", function()
        freshHistory()
        History:add(server, "books")
        History:add(server, "books")
        local _, entry = History:add(server, "books")
        T.eq(entry.count, 3)
        T.eq(#History:list(server), 1)
    end)

    T.test("根目录 \"\" 是合法记录", function()
        freshHistory()
        local ok, entry = History:add(server, "")
        T.eq(ok, true, "根目录应可记录")
        T.eq(entry.dir, "")
        local list = History:list(server)
        T.eq(#list, 1)
        T.eq(list[1].dir, "")
        T.eq(History.formatDir(server, list[1].dir), "/", "根目录显示为 /")
    end)

    T.test("根目录与普通目录是两条不同记录", function()
        freshHistory()
        History:add(server, "")
        History:add(server, "books")
        local list = History:list(server)
        T.eq(#list, 2)
        T.eq(list[1].dir, "books")
        T.eq(list[2].dir, "")
    end)

    T.test("add 归一化多余斜杠与尾斜杠", function()
        freshHistory()
        History:add(server, "//books//sub//")
        local list = History:list(server)
        T.eq(list[1].dir, "books/sub")
    end)

    T.test("add 对 nil dir 视为根目录", function()
        freshHistory()
        local ok, entry = History:add(server, nil)
        T.eq(ok, true)
        T.eq(entry.dir, "")
    end)

    -- ---------------- 按服务器隔离 ----------------

    T.test("两个服务器互不可见", function()
        freshHistory()
        History:add(server, "books")
        History:add(server2, "papers")
        T.eq(#History:list(server), 1)
        T.eq(#History:list(server2), 1)
        T.eq(History:list(server)[1].dir, "books")
        T.eq(History:list(server2)[1].dir, "papers")
    end)

    T.test("按地址派生 id：改服务器名字不丢历史", function()
        freshHistory()
        History:add(server, "books")
        local renamed = { name = "改过名的 NAS", address = server.address }
        local list = History:list(renamed)
        T.eq(#list, 1, "改名后仍能读到历史")
        T.eq(list[1].dir, "books")
    end)

    T.test("未知服务器返回空数组", function()
        freshHistory()
        History:add(server, "books")
        local other = { name = "陌生", address = "https://nowhere.example.com/x" }
        local list = History:list(other)
        T.is_table(list)
        T.eq(#list, 0)
    end)

    T.test("list(nil) 返回空数组", function()
        freshHistory()
        History:add(server, "books")
        local list = History:list(nil)
        T.is_table(list)
        T.eq(#list, 0)
    end)

    T.test("list 同时支持点号与冒号调用", function()
        freshHistory()
        History:add(server, "books")
        History:add(server, "papers")
        -- main.lua / browser.lua 用点号：History.list(server)
        local dot = History.list(server)
        -- 单测与内部用冒号：History:list(server)
        local colon = History:list(server)
        T.eq(#dot, 2, "点号调用应返回 2 条")
        T.eq(#colon, 2, "冒号调用应返回 2 条")
        T.eq(dot[1].dir, colon[1].dir, "两种调用风格结果一致")
        T.eq(History.list(server, 1)[1].dir, "papers", "点号调用也支持 limit 参数")
        -- browser.lua 的写法：pcall(History.list, History, server, limit)
        local ok, l = pcall(History.list, History, server, 2)
        T.eq(ok, true, "pcall + 冒号风格的 list 不应抛错")
        T.eq(#l, 2, "通过 pcall 冒号风格也返回 2 条")
        T.eq(l[1].dir, "papers")
    end)

    T.test("add 支持 browser.lua 的 pcall 冒号写法", function()
        freshHistory()
        -- browser.lua:829 实际写法：pcall(History.add, History, server, target_dir)
        local ok, add_ok, entry, err = pcall(History.add, History, server, "moved/here")
        T.eq(ok, true, "pcall 不应抛错")
        T.eq(add_ok, true, "add 应成功")
        T.eq(entry.dir, "moved/here")
        T.eq(err, nil)
        T.eq(#History:list(server), 1)
    end)

    T.test("同一秒内多次 add 仍按 MRU 排序（时间戳相同）", function()
        -- os.time() 只有秒级分辨率：用户连点几个目录时 used 会完全相同，
        -- 此时必须仍然按「最近用的在前」排，否则界面顺序会随机。
        local store = memStore()
        History:_setStoreForTest(store, "/virtual/history.json")
        History:init("/virtual/history.json")
        History:_setNowForTest(function() return 1700000000 end) -- 时钟固定

        History:add(server, "a")
        History:add(server, "b")
        History:add(server, "c")
        local list = History:list(server)
        T.eq(#list, 3)
        T.eq(list[1].dir, "c", "同一秒内最后 add 的仍在最前")
        T.eq(list[2].dir, "b")
        T.eq(list[3].dir, "a")
        T.eq(list[1].used, list[2].used, "前提：used 确实相同")

        -- 再 add 一个已存在的目录，它应回到最前且 count 累加
        History:add(server, "a")
        local list2 = History:list(server)
        T.eq(list2[1].dir, "a", "重复 add 应提到最前（即使时间戳相同）")
        T.eq(list2[1].count, 2)
        T.eq(#list2, 3, "不应新增条目")
    end)

    -- ---------------- limit ----------------

    T.test("list 默认 limit 为 DEFAULT_LIMIT", function()
        T.eq(History.DEFAULT_LIMIT, 20, "默认每服务器 20 条")
    end)

    T.test("list 的 limit 参数截断结果", function()
        freshHistory()
        History:add(server, "a")
        History:add(server, "b")
        History:add(server, "c")
        local list = History:list(server, 2)
        T.eq(#list, 2)
        T.eq(list[1].dir, "c", "截断时保留最近的")
        T.eq(list[2].dir, "b")
        T.eq(#History:list(server, 100), 3, "limit 大于总数时返回全部")
        T.eq(#History:list(server, 0), 0, "limit=0 返回空")
    end)

    T.test("超过 DEFAULT_LIMIT 时淘汰最旧的一条", function()
        freshHistory()
        local n = History.DEFAULT_LIMIT
        for i = 1, n do
            History:add(server, "d" .. i)
        end
        T.eq(#History:list(server, 1000), n, "恰好等于上限")
        -- 再进一个新目录：总数不变，最旧的 d1 应被淘汰
        History:add(server, "newest")
        local list = History:list(server, 1000)
        T.eq(#list, n, "不应超过上限")
        T.eq(list[1].dir, "newest")
        local found_d1 = false
        for _, e in ipairs(list) do
            if e.dir == "d1" then found_d1 = true end
        end
        T.eq(found_d1, false, "最旧的一条应被淘汰")
    end)

    -- ---------------- remove / clear ----------------

    T.test("remove 删除单条", function()
        freshHistory()
        History:add(server, "books")
        History:add(server, "papers")
        T.eq(History:remove(server, "/books/"), true, "归一化后应能删到")
        local list = History:list(server)
        T.eq(#list, 1)
        T.eq(list[1].dir, "papers")
    end)

    T.test("remove 不存在时返回 false", function()
        freshHistory()
        History:add(server, "books")
        T.eq(History:remove(server, "nope"), false)
    end)

    T.test("remove 根目录记录", function()
        freshHistory()
        History:add(server, "")
        T.eq(History:remove(server, ""), true)
        T.eq(#History:list(server), 0)
    end)

    T.test("clear 单服务器返回删除条数且其他服务器不受影响", function()
        freshHistory()
        History:add(server, "a")
        History:add(server, "b")
        History:add(server2, "c")
        T.eq(History:clear(server), 2)
        T.eq(#History:list(server), 0)
        T.eq(#History:list(server2), 1, "其他服务器保留")
    end)

    T.test("clear(nil) 清空全部服务器", function()
        freshHistory()
        History:add(server, "a")
        History:add(server2, "b")
        T.eq(History:clear(nil), 2)
        T.eq(#History:list(server), 0)
        T.eq(#History:list(server2), 0)
    end)

    T.test("clear 空历史返回 0", function()
        freshHistory()
        T.eq(History:clear(server), 0)
        T.eq(History:clear(nil), 0)
    end)

    -- ---------------- 落盘格式与往返 ----------------

    T.test("add 后立即落盘，JSON 结构符合约定", function()
        local store, files = freshHistory()
        History:add(server, "books/done")
        local content = files["/virtual/history.json"]
        T.ok(content, "应已写盘")
        local decoded, err = json.decode(content)
        T.eq(err, nil, "应是合法 JSON")
        T.eq(decoded.version, 1, "version 1")
        T.is_table(decoded.servers, "servers 字段")
        local sid = Store.getServerId(server)
        local arr = decoded.servers[sid]
        T.is_table(arr, "按 server_id 分组")
        T.eq(#arr, 1)
        T.eq(arr[1].dir, "books/done")
        T.eq(arr[1].count, 1)
        T.ok(type(arr[1].used) == "number", "used 应为数字")
    end)

    T.test("落盘后再 load 读到同样内容（格式往返）", function()
        local store, files = freshHistory()
        History:add(server, "books")
        History:add(server, "papers")
        History:add(server2, "other")
        local before = History:list(server)
        local before2 = History:list(server2)
        local content = files["/virtual/history.json"]

        -- 用同一份文件内容新建 store，模拟「重启 KOReader」
        local store2 = Store.newJsonStore({
            path = "/virtual/history.json",
            default_data = function() return { version = 1, servers = {} } end,
            readfile = function(p) return files[p] end,
            writefile = function(p, c) files[p] = c return true end,
            encode = function(t) return json.encode(t) end,
            decode = function(s)
                local d, e = json.decode(s)
                if e then error(e) end
                return d
            end,
        })
        T.eq(store2:load(), true, "重新加载应成功")
        History:_setStoreForTest(store2, "/virtual/history.json")

        local after = History:list(server)
        T.eq(#after, #before)
        T.eq(after[1].dir, before[1].dir, "顺序应保持")
        T.eq(after[1].count, before[1].count, "count 应保持")
        T.eq(after[1].used, before[1].used, "used 应保持")
        T.eq(#History:list(server2), #before2, "另一个服务器也应保持")
        T.ok(content, "文件仍存在")
    end)

    T.test("历史文件与进度文件互相独立", function()
        local path = Config:getHistoryPath()
        T.contains(path, "webdavreader_history.json")
        T.neq(path, Config:getProgressPath(), "不能和进度共用同一个文件")
        T.not_contains(path, "webdavreader_progress.json")
    end)

    -- ---------------- 损坏 / 缺失文件 ----------------

    T.test("损坏 JSON：兜底为空历史并产生 .corrupt- 备份", function()
        local files = { ["/virtual/history.json"] = "{ this is not json" }
        local store = memStore({ files = files })
        local backups = {}
        store._write = function(p, content)
            backups[#backups + 1] = p
            files[p] = content
            return true
        end
        store:load()
        History:_setStoreForTest(store, "/virtual/history.json")

        T.eq(#History:list(server), 0, "损坏文件应兜底为空历史")
        local found = false
        for _, p in ipairs(backups) do
            if p:find("%.corrupt%-") then found = true end
        end
        T.ok(found, "损坏文件应被备份")
        -- 仍可正常继续记录（不能被坏文件永久卡死）
        local ok = History:add(server, "books")
        T.eq(ok, true, "损坏后应还能写入")
        T.eq(#History:list(server), 1)
    end)

    T.test("文件不存在时视为空历史", function()
        local files = {}
        local store = memStore({ files = files })
        T.eq(store:load(), true, "文件不存在不算错误")
        History:_setStoreForTest(store, "/virtual/history.json")
        T.eq(#History:list(server), 0)
    end)

    T.test("空文件视为空历史", function()
        local files = { ["/virtual/history.json"] = "" }
        local store = memStore({ files = files })
        T.eq(store:load(), true)
        History:_setStoreForTest(store, "/virtual/history.json")
        T.eq(#History:list(server), 0)
    end)

    T.test("旧版本文件缺 servers 字段时自动补全", function()
        local files = { ["/virtual/history.json"] = '{"version":1}' }
        local store = memStore({ files = files })
        T.eq(store:load(), true)
        History:_setStoreForTest(store, "/virtual/history.json")
        T.eq(#History:list(server), 0, "缺字段不应崩溃")
        T.eq(History:add(server, "books"), true, "补全后应可写入")
    end)

    -- ---------------- 未初始化 ----------------

    T.test("未初始化时方法安全返回", function()
        local saved_store, saved_path = History.store, History.path
        History.store = nil
        History.path = nil
        T.eq(#History:list(server), 0, "list 返回空数组")
        local ok, entry, err = History:add(server, "books")
        T.eq(ok, false, "add 应失败")
        T.eq(entry, nil)
        T.ok(err, "应给出错误信息")
        T.eq(History:remove(server, "books"), false)
        T.eq(History:clear(server), 0)
        T.eq(History:flush(), true, "未初始化时 flush 视为成功")
        T.eq(History:getPath(), nil)
        History.store, History.path = saved_store, saved_path
    end)

    T.test("init 幂等：path 不变时复用同一个 store", function()
        freshHistory()
        local store_before = History.store
        History:init("/virtual/history.json")
        T.eq(History.store, store_before, "path 不变应复用 store（不重新读盘）")
        -- 复用后仍能正常写入（不会因为没重新 init 而失效）
        T.eq(History:add(server, "after_reinit"), true)
        T.eq(#History:list(server), 1)
    end)

    T.test("init 在 path 变化时重建 store", function()
        freshHistory()
        local store_before = History.store
        History:init("/virtual/other_history.json")
        T.neq(History.store, store_before, "path 变化应重建 store")
        T.eq(History:getPath(), "/virtual/other_history.json")
        T.eq(#History:list(server), 0, "新路径应没有旧记录")
    end)

    T.test("init() 无参数时用 Config:getHistoryPath() 兜底", function()
        local saved_store, saved_path = History.store, History.path
        History:_setStoreForTest(nil, nil)
        History:init()
        T.eq(History:getPath(), Config:getHistoryPath(), "应回落到默认历史路径")
        T.is_table(History.store, "应创建 store")
        -- 能正常记录并落盘（目录由 ensureDir 自动创建）
        local ok = History:add(server, "books")
        T.eq(ok, true, "默认路径下也应能写入")
        local lfs = require("lfs")
        T.eq(lfs.attributes(Config:getHistoryPath(), "mode"), "file", "应真的落盘")
        os.remove(Config:getHistoryPath())
        History:_setStoreForTest(saved_store, saved_path)
    end)

    -- ---------------- 纯函数：formatDir / formatLabel ----------------

    T.test("formatDir 根目录返回 /", function()
        T.eq(History.formatDir(server, ""), "/")
        T.eq(History.formatDir(server, nil), "/")
        T.eq(History.formatDir(server, "/"), "/")
    end)

    T.test("formatDir 普通目录带前导斜杠、不带尾斜杠", function()
        T.eq(History.formatDir(server, "books"), "/books")
        T.eq(History.formatDir(server, "/books/"), "/books")
        T.eq(History.formatDir(server, "//books//done//"), "/books/done")
    end)

    T.test("formatLabel count>1 时显示次数", function()
        local label = History.formatLabel({ dir = "books/done", used = 100, count = 3 })
        T.eq(label, "/books/done   3 次", "文案形如 \"/books/done   3 次\"")
        T.contains(label, "/books/done", "应含目录")
        T.contains(label, "3", "应含次数")
        T.contains(label, "次", "应含「次」文案")
    end)

    T.test("formatLabel count<=1 时不显示次数", function()
        T.eq(History.formatLabel({ dir = "books/done", used = 100, count = 1 }),
             "/books/done")
        T.eq(History.formatLabel({ dir = "books/done", used = 100 }),
             "/books/done", "缺 count 时按 1 处理")
        T.eq(History.formatLabel({ dir = "", count = 1 }), "/")
    end)

    T.test("formatLabel 根目录 + 次数", function()
        local label = History.formatLabel({ dir = "", used = 100, count = 2 })
        T.contains(label, "/")
        T.contains(label, "2")
    end)

    T.test("formatLabel 对 nil / 非 table 安全", function()
        T.eq(History.formatLabel(nil), "")
        T.eq(History.formatLabel("nonsense"), "")
    end)

    -- ---------------- JsonStore：dirty / flushIfDirty / 无 encoder ----------------

    T.test("JsonStore 懒加载：构造时不读盘", function()
        local reads = 0
        local store = Store.newJsonStore({
            path = "/virtual/lazy.json",
            readfile = function() reads = reads + 1 return nil end,
            writefile = function() return true end,
            encode = function(t) return json.encode(t) end,
            decode = function(s) return json.decode(s) end,
        })
        T.eq(reads, 0, "构造时不应读盘")
        T.is_table(store:getData(), "getData 返回 table")
        T.eq(reads, 1, "getData 触发一次读盘")
        store:getData()
        T.eq(reads, 1, "之后不再重复读盘")
    end)

    T.test("JsonStore getData 返回 default_data 的形状", function()
        local store = Store.newJsonStore({
            path = "/virtual/d.json",
            default_data = function() return { version = 1, servers = {} } end,
            readfile = function() return nil end,
            writefile = function() return true end,
            encode = function(t) return json.encode(t) end,
            decode = function(s) return json.decode(s) end,
        })
        local data = store:getData()
        T.eq(data.version, 1)
        T.is_table(data.servers)
    end)

    T.test("JsonStore default_data 缺省时给空 table", function()
        local store = Store.newJsonStore({ path = "/virtual/n.json" })
        T.is_table(store:getData())
    end)

    T.test("JsonStore dirty 语义：setData 置位，flush 清除", function()
        local store, files = memStore()
        T.eq(store:isDirty(), false, "初始不脏")
        store:setData({ version = 1, servers = {} })
        T.eq(store:isDirty(), true, "setData 后应脏")
        T.eq(store:flush(), true)
        T.eq(store:isDirty(), false, "flush 后不脏")
        T.ok(files["/virtual/history.json"], "应写入文件")
    end)

    T.test("JsonStore markDirty 置位", function()
        local store = memStore()
        store:getData()
        T.eq(store:isDirty(), false)
        store:markDirty()
        T.eq(store:isDirty(), true)
    end)

    T.test("JsonStore flushIfDirty 无改动不写", function()
        local store, _, writes = memStore()
        store:getData()
        store:setData({ version = 1, servers = {} })
        store:flush()
        local before = writes()
        T.eq(store:flushIfDirty(), true)
        T.eq(writes(), before, "不脏时不应重写")
        store:markDirty()
        store:flushIfDirty()
        T.eq(writes(), before + 1, "脏时应写入")
    end)

    T.test("JsonStore 无 path 时 flush 返回 false, err", function()
        local store = Store.newJsonStore({ encode = function(t) return json.encode(t) end })
        local ok, err = store:flush()
        T.eq(ok, false)
        T.ok(err, "应给出错误信息")
    end)

    T.test("JsonStore 无 encoder 时 flush 返回 false, \"no encoder\"", function()
        local store = Store.newJsonStore({
            path = "/virtual/x.json",
            readfile = function() return '{"version":1,"servers":{}}' end,
        })
        T.eq(store:load(), false, "有内容但没有解码器时 load 返回 false")
        T.is_table(store:getData(), "仍能拿到默认数据，不会崩溃")
        local ok, err = store:flush()
        T.eq(ok, false)
        T.contains(tostring(err), "encoder", "错误信息应提到 encoder")
    end)

    T.test("JsonStore setCodec 可后置注入编解码器", function()
        local files = {}
        local store = Store.newJsonStore({
            path = "/virtual/late.json",
            readfile = function(p) return files[p] end,
            writefile = function(p, c) files[p] = c return true end,
        })
        store:setCodec(function(t) return json.encode(t) end, function(s)
            local d, e = json.decode(s)
            if e then error(e) end
            return d
        end)
        store:setData({ version = 1, servers = {} })
        T.eq(store:flush(), true, "注入后应能落盘")
        T.eq(type(files["/virtual/late.json"]), "string", "落盘内容是 JSON 字符串")
        T.is_table(json.decode(files["/virtual/late.json"]), "解码后是 table")
    end)

    T.test("JsonStore 编码器抛错时 flush 返回 false 而不是崩溃", function()
        local store = Store.newJsonStore({
            path = "/virtual/e.json",
            readfile = function() return nil end,
            writefile = function() return true end,
            encode = function() error("boom") end,
        })
        local ok, err = store:flush()
        T.eq(ok, false)
        T.ok(err, "应带回编码错误")
    end)

    T.test("JsonStore 写入失败时 flush 返回 false, err", function()
        local store = Store.newJsonStore({
            path = "/virtual/w.json",
            readfile = function() return nil end,
            writefile = function() return nil, "disk full" end,
            encode = function(t) return json.encode(t) end,
        })
        local ok, err = store:flush()
        T.eq(ok, false)
        T.eq(err, "disk full")
    end)

    return M
end

return M
