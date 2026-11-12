--[[--
wdr/manager.lua 单测

两种运行方式都支持：
    cd /home/riko/koreader-plugin && ./tools/lua tests/test_manager.lua
    cd /home/riko/koreader-plugin && ./tools/lua tests/run_all.lua manager

测试不依赖 wdr/webdav.lua / wdr/progress.lua / wdr/cache.lua 的真实实现，
client / progress / cache 全部是假对象；wdr.store 依赖的 ffi/sha2 用桩件替代。
--]]--

-- 由 run_all.lua 加载时，它已经设好 package.path 并安装桩件；
-- 独立运行时（arg[0] 是本文件）需要自己准备。
local is_standalone = not (arg and arg[0] and arg[0]:match("run_all%.lua$"))

package.path = "./webdavreader.koplugin/?.lua;" .. package.path

if not (package.loaded["ffi/sha2"] or package.preload["ffi/sha2"]) then
    package.loaded["ffi/sha2"] = {
        md5 = function(s)
            local h = 5381
            for i = 1, #tostring(s or "") do
                h = (h * 33 + s:byte(i)) % 2147483647
            end
            return string.format("%08x%08x%08x%08x", h, h + 1, h + 2, h + 3)
        end,
    }
end

local Store = require("wdr.store")
local Manager = require("wdr.manager")

local R
local function check(...) return R.check(...) end
local function eq(...) return R.eq(...) end
local function section(t) return R.section(t) end

-- ---------------------------------------------------------------------------
-- 报告器：独立运行时逐条打印并汇总；随 run_all 运行时转发给它的断言器
-- ---------------------------------------------------------------------------

local function newStandaloneReport()
    local passed, failed = 0, 0
    local failures = {}
    local r = {}
    function r.section(title)
        io.write(string.format("\n== %s ==\n", title))
    end
    function r.case(name, fn)
        local ok, err = pcall(fn)
        if not ok then
            failed = failed + 1
            local msg = name .. "  <" .. tostring(err) .. ">"
            table.insert(failures, msg)
            io.write("FAIL  " .. msg .. "\n")
        end
    end
    function r.check(cond, label, detail)
        if cond then
            passed = passed + 1
            io.write("PASS  " .. label .. "\n")
        else
            failed = failed + 1
            local msg = label .. (detail and ("  <" .. tostring(detail) .. ">") or "")
            table.insert(failures, msg)
            io.write("FAIL  " .. msg .. "\n")
        end
    end
    function r.eq(actual, expected, label)
        r.check(actual == expected, label,
            string.format("expected %s, got %s", tostring(expected), tostring(actual)))
    end
    function r.finish()
        io.write("\n----------------------------------------\n")
        io.write(string.format("总计: %d 通过, %d 失败\n", passed, failed))
        if failed > 0 then
            io.write("失败用例:\n")
            for _, m in ipairs(failures) do
                io.write("  - " .. m .. "\n")
            end
            os.exit(1)
        end
        io.write("全部 PASS\n")
        os.exit(0)
    end
    return r
end

local function newSuiteReport(T)
    local r = {}
    function r.section(title)
        io.write(string.format("\n  ### manager · %s\n", title))
    end
    function r.case(name, fn)
        T.test(name, fn)
    end
    function r.check(cond, label, detail)
        if not cond then
            error(label .. (detail and ("  [" .. tostring(detail) .. "]") or ""), 2)
        end
    end
    function r.eq(actual, expected, label)
        r.check(actual == expected, label,
            string.format("期望 %s，实际 %s", tostring(expected), tostring(actual)))
    end
    function r.finish() end
    return r
end

-- ---------------------------------------------------------------------------
-- 假对象
-- ---------------------------------------------------------------------------

local function norm(path)
    return Store.normalizeDir(path)
end

--- 假 WebDAV 客户端。
-- @param trees table 路径 -> 子项数组（每项 { name=, path=, is_folder=, size= }）
-- @param opts table { list_error=, delete_error=, move_error=, mkdir_error=, exists= }
local function newClient(trees, opts)
    opts = opts or {}
    local c = {
        trees = trees or {},
        lists = {},
        deleted = {},
        moved = {},
        mkdirs = {},
        exists_map = opts.exists or {},
    }
    function c:list(path)
        path = norm(path)
        table.insert(self.lists, path)
        if opts.list_error then return nil, opts.list_error end
        local items = self.trees[path]
        return items or {}, nil
    end
    function c:delete(path)
        path = norm(path)
        table.insert(self.deleted, path)
        if opts.delete_error then return false, opts.delete_error end
        return true
    end
    function c:move(from, to)
        table.insert(self.moved, { from = norm(from), to = norm(to) })
        if opts.move_error then return false, opts.move_error end
        return true
    end
    function c:mkdir(path)
        table.insert(self.mkdirs, norm(path))
        if opts.mkdir_error then return false, opts.mkdir_error end
        return true
    end
    function c:exists(path)
        if self.exists_map[norm(path)] then return true, false, nil end
        return false, nil, nil
    end
    return c
end

--- 假进度层（记录调用，验证联动）。
local function newProgress()
    local p = { removed = {}, renamed = {} }
    function p:remove(server, path) table.insert(self.removed, norm(path)) end
    -- 与 wdr/progress.lua 实际签名一致：rename(server, old_path, new_path)
    function p:rename(server, old_path, new_path)
        table.insert(self.renamed, { from = norm(old_path), to = norm(new_path) })
    end
    return p
end

--- 假缓存层。
local function newCache()
    local c = { invalidated = {} }
    function c:invalidate(server, path) table.insert(self.invalidated, norm(path)) end
    return c
end

--- 组装一个管理器。
local function newManager(opts)
    opts = opts or {}
    local progress = opts.progress or newProgress()
    local cache = opts.cache or newCache()
    local m = Manager:new({
        progress = progress,
        cache = cache,
        get_client = opts.get_client or function() return opts.client end,
        max_depth = opts.max_depth,
        max_items = opts.max_items,
    })
    return m, progress, cache
end

local SERVER = { name = "test", address = "https://example.com/dav/", username = "u", password = "p" }

local function runSuite()
    section("validateName")
    
    R.case("validateName#1", function()
            local m = newManager({ client = newClient() })
        
            local cases = {
                { "book.txt", true },              -- 常规英文名
                { "My Book (2024).epub", true },   -- 空格与括号
                { "三体.txt", true },              -- 中文名
                { "报告-终稿.epub", true },        -- 中文 + 连字符
                { "a", true },                     -- 单字符
                { "with_underscore-and-dash", true },
                { "", false },                     -- 空
                { "   ", false },                  -- 仅空格
                { "   name", true },               -- 前导空格允许（只禁尾随）
                { ".", false },                    -- 当前目录
                { "..", false },                   -- 上级目录
                { "a/b.txt", false },              -- 含斜杠
                { "a\\b.txt", false },             -- 含反斜杠
                { "a:b.txt", false },              -- 冒号
                { "a*b.txt", false },              -- 星号
                { "a?b.txt", false },              -- 问号
                { 'a"b.txt', false },              -- 双引号
                { "a<b>.txt", false },             -- 尖括号
                { "a|b.txt", false },              -- 竖线
                { "trailing.", false },            -- 以点结尾
                { "trailing ", false },            -- 以空格结尾
                { nil, false },                    -- nil
                { string.rep("x", 256), false },   -- 超长
            }
        
            for _, case in ipairs(cases) do
                local name, expect_ok = case[1], case[2]
                local ok, err = m:validateName(name)
                local label = string.format("validateName(%s) -> %s",
                    name == nil and "nil" or string.format("%q", name), tostring(expect_ok))
                check(ok == expect_ok, label, "err=" .. tostring(err))
                if not ok then
                    check(type(err) == "string" and #err > 0, "  error message is a non-empty string")
                end
            end
    end)
    
    -- ---------------------------------------------------------------------------
    -- b) deleteFile
    -- ---------------------------------------------------------------------------
    
    section("deleteFile")
    
    R.case("deleteFile#2", function()
            -- 成功分支
            local client = newClient()
            local m, progress, cache = newManager({ client = client })
            local ok, err = m:deleteFile(SERVER, "docs/a.txt")
            eq(ok, true, "deleteFile 成功返回 true")
            eq(err, nil, "deleteFile 成功无错误")
            eq(client.deleted[1], "docs/a.txt", "deleteFile 调用 client:delete 且路径归一化")
            eq(progress.removed[1], "docs/a.txt", "deleteFile 成功后移除进度")
            eq(cache.invalidated[1], "docs/a.txt", "deleteFile 成功后失效缓存")
        
            -- 带前导斜杠的路径被归一化
            local client2 = newClient()
            local m2, p2 = newManager({ client = client2 })
            eq(m2:deleteFile(SERVER, "/docs/b.txt"), true, "deleteFile 接受前导斜杠")
            eq(client2.deleted[1], "docs/b.txt", "deleteFile 去掉前导斜杠")
            eq(p2.removed[1], "docs/b.txt", "deleteFile 进度键无前导斜杠")
    end)
    
    R.case("deleteFile#3", function()
            -- 失败分支：进度与缓存必须保持不变
            local client = newClient(nil, { delete_error = "HTTP 403 Forbidden" })
            local m, progress, cache = newManager({ client = client })
            local ok, err = m:deleteFile(SERVER, "docs/a.txt")
            eq(ok, false, "deleteFile 失败返回 false")
            eq(err, "Delete failed: HTTP 403 Forbidden", "deleteFile 失败错误带操作名前缀")
            eq(#progress.removed, 0, "deleteFile 失败时进度未被删除")
            eq(#cache.invalidated, 0, "deleteFile 失败时缓存未失效")
        
            -- 根路径拒绝
            local ok2, err2 = m:deleteFile(SERVER, "")
            eq(ok2, false, "deleteFile 拒绝对根路径操作")
            check(type(err2) == "string", "deleteFile 根路径给出错误消息")
        
            -- 无客户端
            local m_noclient = newManager({ get_client = function() return nil end })
            local ok3, err3 = m_noclient:deleteFile(SERVER, "a.txt")
            eq(ok3, false, "deleteFile 无客户端时返回 false")
            check(type(err3) == "string", "deleteFile 无客户端时给出错误消息")
    end)
    
    -- ---------------------------------------------------------------------------
    -- c) countFolderItems / deleteFolder
    -- ---------------------------------------------------------------------------
    
    -- 构造一棵树：
    --   books/           (root)
    --     a.txt
    --     readme.md
    --     sub/
    --       b.txt
    --       deep/
    --         c.txt
    local TREE = {
        ["books"] = {
            { name = "a.txt", path = "books/a.txt", is_folder = false },
            { name = "readme.md", path = "books/readme.md", is_folder = false },
            { name = "sub", path = "books/sub", is_folder = true },
        },
        ["books/sub"] = {
            { name = "b.txt", path = "books/sub/b.txt", is_folder = false },
            { name = "deep", path = "books/sub/deep", is_folder = true },
        },
        ["books/sub/deep"] = {
            { name = "c.txt", path = "books/sub/deep/c.txt", is_folder = false },
        },
    }
    
    section("countFolderItems")
    
    R.case("countFolderItems#4", function()
            local client = newClient(TREE)
            local m = newManager({ client = client })
            local files, folders, err = m:countFolderItems(SERVER, "books")
            eq(files, 4, "countFolderItems 文件数正确（a.txt, readme.md, b.txt, c.txt 共 4 个）")
            eq(folders, 2, "countFolderItems 目录数正确（sub, deep）")
            eq(err, nil, "countFolderItems 成功无错误")
            eq(client.deleted ~= nil, true, "countFolderItems 不删除任何东西")
            eq(#client.deleted, 0, "countFolderItems 未调用 delete")
    end)
    
    section("deleteFolder")
    
    R.case("deleteFolder#5", function()
            local client = newClient(TREE)
            local m, progress, cache = newManager({ client = client })
            local ok, count, err = m:deleteFolder(SERVER, "books")
            eq(ok, true, "deleteFolder 成功返回 true")
            eq(count, 6, "deleteFolder 返回被删除的子项数（4 文件 + 2 目录）")
            eq(err, nil, "deleteFolder 成功无错误")
        
            -- 后序：子项先于父目录，深层先于浅层
            local expected = {
                "books/a.txt",
                "books/readme.md",
                "books/sub/b.txt",
                "books/sub/deep/c.txt",   -- 注意：deep 的递归先于 sub/deep 自身的删除
                "books/sub/deep",
                "books/sub",
                "books",
            }
            -- 实际顺序由 _scan 的后序生成，这里逐项校验
            local actual = table.concat(client.deleted, ",")
            local want = table.concat(expected, ",")
            eq(actual, want, "deleteFolder 删除顺序为自底向上（先子后父）")
        
            local sub_idx, root_idx, deep_idx = nil, nil, nil
            for i, path in ipairs(client.deleted) do
                if path == "books" then root_idx = i end
                if path == "books/sub" then sub_idx = i end
                if path == "books/sub/deep" then deep_idx = i end
            end
            check(sub_idx < root_idx, "子目录在父目录之前被删除")
            check(deep_idx < sub_idx, "深层目录在浅层目录之前被删除")
        
            eq(#progress.removed, 7, "deleteFolder 为每个删除项清理进度")
            eq(#cache.invalidated, 7, "deleteFolder 为每个删除项失效缓存")
    end)
    
    R.case("deleteFolder#6", function()
            -- 删除中途失败：返回错误，且错误带路径前缀
            local client = newClient(TREE, { delete_error = "HTTP 500 Internal Server Error" })
            local m = newManager({ client = client })
            local ok, count, err = m:deleteFolder(SERVER, "books")
            eq(ok, false, "deleteFolder 中途失败返回 false")
            eq(err ~= nil, true, "deleteFolder 中途失败给出错误")
            check(err and err:find("HTTP 500", 1, true) ~= nil, "deleteFolder 保留底层英文错误")
        
            -- 空目录也能删
            local empty_client = newClient({ ["empty"] = {} })
            local me = newManager({ client = empty_client })
            local ok2, count2 = me:deleteFolder(SERVER, "empty")
            eq(ok2, true, "deleteFolder 可删除空目录")
            eq(count2, 0, "deleteFolder 空目录计数为 0")
            eq(table.concat(empty_client.deleted, ","), "empty", "空目录只删除目录自身")
        
            -- 根路径拒绝
            local ok3, _, err3 = m:deleteFolder(SERVER, "/")
            eq(ok3, false, "deleteFolder 拒绝删除服务器根目录")
            check(type(err3) == "string", "deleteFolder 根路径给出错误消息")
    end)
    
    -- ---------------------------------------------------------------------------
    -- d) moveItem
    -- ---------------------------------------------------------------------------
    
    section("moveItem")
    
    R.case("moveItem#7", function()
            local client = newClient()
            local m, progress, cache = newManager({ client = client })
            local ok, err = m:moveItem(SERVER, "docs/a.txt", "archive/a.txt")
            eq(ok, true, "moveItem 成功返回 true")
            eq(err, nil, "moveItem 成功无错误")
            eq(client.moved[1].from, "docs/a.txt", "moveItem 调用 client:move 源路径正确")
            eq(client.moved[1].to, "archive/a.txt", "moveItem 调用 client:move 目标路径正确")
            eq(#progress.renamed, 1, "moveItem 成功后迁移进度键")
            eq(progress.renamed[1].from, "docs/a.txt", "进度迁移旧键正确")
            eq(progress.renamed[1].to, "archive/a.txt", "进度迁移新键正确")
            eq(cache.invalidated[1], "docs/a.txt", "moveItem 成功后失效旧路径缓存")
            eq(#progress.removed, 0, "moveItem 不删除进度记录")
    end)
    
    R.case("moveItem#8", function()
            local client = newClient(nil, { move_error = "HTTP 409 Conflict" })
            local m, progress, cache = newManager({ client = client })
            local ok, err = m:moveItem(SERVER, "docs/a.txt", "archive/a.txt")
            eq(ok, false, "moveItem 失败返回 false")
            eq(err, "Move failed: HTTP 409 Conflict", "moveItem 失败错误带操作名前缀")
            eq(#progress.renamed, 0, "moveItem 失败时进度键保持不变")
            eq(#progress.removed, 0, "moveItem 失败时进度未被删除")
            eq(#cache.invalidated, 0, "moveItem 失败时缓存未失效")
        
            -- 同路径移动被拒绝（不发请求）
            local ok2, err2 = m:moveItem(SERVER, "docs/a.txt", "docs/a.txt")
            eq(ok2, false, "moveItem 拒绝源=目标")
            check(type(err2) == "string", "moveItem 源=目标给出错误消息")
            eq(#client.moved, 1, "moveItem 源=目标未发请求")
    end)
    
    -- ---------------------------------------------------------------------------
    -- e) renameFile
    -- ---------------------------------------------------------------------------
    
    section("renameFile")
    
    R.case("renameFile#9", function()
            local client = newClient()
            local m, progress = newManager({ client = client })
            local ok, new_path, err = m:renameFile(SERVER, "docs/report 2024.txt", "报告.txt")
            eq(ok, true, "renameFile 成功返回 true")
            eq(new_path, "docs/报告.txt", "renameFile 生成正确的新路径（保留目录）")
            eq(err, nil, "renameFile 成功无错误")
            eq(client.moved[1].from, "docs/report 2024.txt", "renameFile 源路径正确")
            eq(client.moved[1].to, "docs/报告.txt", "renameFile 目标路径正确")
            eq(progress.renamed[1].to, "docs/报告.txt", "renameFile 迁移进度键")
        
            -- 根目录下的文件
            local ok2, np2 = m:renameFile(SERVER, "readme.md", "README.md")
            eq(ok2, true, "renameFile 可处理根目录文件")
            eq(np2, "README.md", "renameFile 根目录文件新路径无前导斜杠")
        
            -- 非法新名字
            local ok3, np3, err3 = m:renameFile(SERVER, "docs/a.txt", "bad/name.txt")
            eq(ok3, false, "renameFile 拒绝非法新名字")
            eq(np3, nil, "renameFile 失败时不返回新路径")
            check(type(err3) == "string", "renameFile 非法名字给出错误消息")
        
            -- 与原名相同
            local ok4, _, err4 = m:renameFile(SERVER, "docs/a.txt", "a.txt")
            eq(ok4, false, "renameFile 拒绝与原名相同")
            check(type(err4) == "string", "renameFile 同名给出错误消息")
        
            -- 目标已存在
            local exists_client = newClient()
            local me = newManager({ client = exists_client })
            local ok5, _, err5 = me:renameFile(SERVER, "docs/a.txt", "b.txt")
            eq(ok5, true, "renameFile 目标不存在时可改名")
            local client_ex = newClient(nil, { exists = { ["docs/b.txt"] = true } })
            local mex = newManager({ client = client_ex })
            local ok6, _, err6 = mex:renameFile(SERVER, "docs/a.txt", "b.txt")
            eq(ok6, false, "renameFile 目标已存在时拒绝")
            check(err6 and err6:find("exists", 1, true) ~= nil, "renameFile 目标已存在给出明确提示")
            eq(#client_ex.moved, 0, "renameFile 目标已存在时未发请求")
        
            -- move 失败时不改进度
            local fail_client = newClient(nil, { move_error = "HTTP 423 Locked" })
            local mf, pf = newManager({ client = fail_client })
            local ok7, np7, err7 = mf:renameFile(SERVER, "docs/a.txt", "b.txt")
            eq(ok7, false, "renameFile 底层 move 失败时返回 false")
            eq(np7, nil, "renameFile 底层失败时不返回新路径")
            eq(#pf.renamed, 0, "renameFile 底层失败时进度不变")
            check(err7 and err7:find("Move failed", 1, true) ~= nil, "renameFile 保留 move 错误前缀")
    end)
    
    -- ---------------------------------------------------------------------------
    -- f) createFolder
    -- ---------------------------------------------------------------------------
    
    section("createFolder")
    
    R.case("createFolder#10", function()
            local client = newClient()
            local m = newManager({ client = client })
            local ok, new_path, err = m:createFolder(SERVER, "docs", "新目录")
            eq(ok, true, "createFolder 成功返回 true")
            eq(new_path, "docs/新目录", "createFolder 生成正确路径")
            eq(err, nil, "createFolder 成功无错误")
            eq(client.mkdirs[1], "docs/新目录", "createFolder 调用 client:mkdir")
        
            local ok2, np2 = m:createFolder(SERVER, "", "root-level")
            eq(ok2, true, "createFolder 可建在根目录")
            eq(np2, "root-level", "根目录新建路径无前导斜杠")
        
            local ok3, np3, err3 = m:createFolder(SERVER, "docs", "bad/name")
            eq(ok3, false, "createFolder 拒绝非法名字")
            eq(np3, nil, "createFolder 失败不返回路径")
            check(type(err3) == "string", "createFolder 非法名字给出错误消息")
        
            local ok4, np4, err4 = m:createFolder(SERVER, "docs", "..")
            eq(ok4, false, "createFolder 拒绝 ..")
        
            local fail_client = newClient(nil, { mkdir_error = "HTTP 405 Method Not Allowed" })
            local mf = newManager({ client = fail_client })
            local ok5, np5, err5 = mf:createFolder(SERVER, "docs", "x")
            eq(ok5, false, "createFolder 底层失败时返回 false")
            eq(np5, nil, "createFolder 底层失败不返回路径")
            eq(err5, "Create folder failed: HTTP 405 Method Not Allowed",
                "createFolder 失败错误带操作名前缀")
    end)
    
    -- ---------------------------------------------------------------------------
    -- g) validateMoveTarget
    -- ---------------------------------------------------------------------------
    
    section("validateMoveTarget")
    
    R.case("validateMoveTarget#11", function()
            local client = newClient(nil, { exists = { ["docs/taken.txt"] = true } })
            local m = newManager({ client = client })
        
            local ok1, err1 = m:validateMoveTarget(SERVER, "docs/a.txt", "archive/a.txt")
            eq(ok1, true, "validateMoveTarget 合法目标通过")
            eq(err1, nil, "validateMoveTarget 合法目标无错误")
        
            local ok2 = m:validateMoveTarget(SERVER, "docs/a.txt", "docs/a.txt")
            eq(ok2, false, "validateMoveTarget 拒绝相同路径")
        
            local ok3 = m:validateMoveTarget(SERVER, "docs", "docs/sub")
            eq(ok3, false, "validateMoveTarget 拒绝移入自身子目录")
        
            local ok4 = m:validateMoveTarget(SERVER, "docs/a.txt", "docs/taken.txt")
            eq(ok4, false, "validateMoveTarget 拒绝已存在的目标")
        
            local ok5 = m:validateMoveTarget(SERVER, "docs/a.txt", "")
            eq(ok5, false, "validateMoveTarget 拒绝空目标")
        
            local ok6 = m:validateMoveTarget(SERVER, "", "docs/a.txt")
            eq(ok6, false, "validateMoveTarget 拒绝空源")
        
            local ok7 = m:validateMoveTarget(SERVER, "docs/a.txt", "docs/b:c")
            eq(ok7, false, "validateMoveTarget 拒绝非法目标名")
        
            -- 名字前缀相同但不是子目录（docs 与 docs2）不应误判
            local ok8 = m:validateMoveTarget(SERVER, "docs", "docs2")
            eq(ok8, true, "validateMoveTarget 不把 docs2 当作 docs 的子目录")
    end)
    
    -- ---------------------------------------------------------------------------
    -- 安全阀：深度 / 条目上限
    -- ---------------------------------------------------------------------------
    
    section("递归安全阀")
    
    R.case("递归安全阀#12", function()
            -- 构造 12 层嵌套目录链：d1/d2/.../d12
            local trees = {}
            local dir_path = "d1"
            for i = 1, 12 do
                local entry_path = dir_path .. "/d" .. (i + 1)
                if i < 12 then
                    trees[dir_path] = {
                        { name = "d" .. (i + 1), path = entry_path, is_folder = true },
                    }
                else
                    trees[dir_path] = {}
                end
                dir_path = entry_path
            end
            local client = newClient(trees)
            local m = newManager({ client = client, max_depth = 8 })
            local ok, count, err = m:deleteFolder(SERVER, "d1")
            eq(ok, false, "超过最大深度时返回错误而非无限递归")
            eq(count, nil, "超深度失败时不返回计数")
            check(err ~= nil and err:find("nesting", 1, true) ~= nil,
                "超深度错误说明是嵌套层数问题", tostring(err))
            eq(#client.deleted, 0, "超深度时未删除任何条目（先统计后删除）")
        
            -- 统计接口同样受保护
            local files, folders, cerr = m:countFolderItems(SERVER, "d1")
            eq(files, nil, "countFolderItems 超深度返回 nil")
            eq(folders, nil, "countFolderItems 超深度不返回目录数")
            check(cerr ~= nil, "countFolderItems 超深度给出错误")
        
            -- 放宽深度后应当成功：d1/d2/.../d12 中 d1 的子项是 d2..d12 共 11 个
            local m2 = newManager({ client = newClient(trees), max_depth = 20 })
            local ok2, count2 = m2:deleteFolder(SERVER, "d1")
            eq(ok2, true, "放宽 max_depth 后删除成功")
            eq(count2, 11, "12 层目录链计 11 个子项（不含根目录自身）")
    end)
    
    R.case("递归安全阀#13", function()
            -- 条目上限：根目录下有 5 个文件，max_items = 3
            local many = {}
            for i = 1, 5 do
                table.insert(many, { name = "f" .. i .. ".txt", path = "many/f" .. i .. ".txt", is_folder = false })
            end
            local client = newClient({ many = many })
            local m = newManager({ client = client, max_items = 3 })
            local ok, count, err = m:deleteFolder(SERVER, "many")
            eq(ok, false, "超过条目上限时返回错误")
            eq(count, nil, "超条目上限时不返回计数")
            check(err ~= nil and err:find("items", 1, true) ~= nil,
                "超条目错误说明是条目数问题", tostring(err))
            eq(#client.deleted, 0, "超条目上限时未删除任何条目")
        
            -- 正好等于上限时允许（3 个文件，max_items = 3）
            local three = {}
            for i = 1, 3 do
                table.insert(three, { name = "g" .. i .. ".txt", path = "three/g" .. i .. ".txt", is_folder = false })
            end
            local m2 = newManager({ client = newClient({ three = three }), max_items = 3 })
            local ok2, count2 = m2:deleteFolder(SERVER, "three")
            eq(ok2, true, "条目数等于上限时允许删除")
            eq(count2, 3, "等于上限时计数正确")
    end)
    
    R.case("递归安全阀#14", function()
            -- list 失败时要带操作名前缀，且不删除
            local client = newClient(nil, { list_error = "HTTP 401 Unauthorized" })
            local m = newManager({ client = client })
            local ok, count, err = m:deleteFolder(SERVER, "books")
            eq(ok, false, "list 失败时 deleteFolder 返回 false")
            eq(count, nil, "list 失败时不返回计数")
            check(err == "List failed: HTTP 401 Unauthorized", "list 失败错误带操作名前缀", tostring(err))
            eq(#client.deleted, 0, "list 失败时未删除任何东西")
    end)
    
    -- ---------------------------------------------------------------------------
    -- h) 契约与副作用检查
    -- ---------------------------------------------------------------------------
    
    section("契约检查")
    
    R.case("契约检查#15", function()
            check(Manager ~= nil and type(Manager) == "table", "模块返回 table 单例")
            check(type(Manager.new) == "function", "模块提供 new 构造")
            for _, f in ipairs({ "deleteFile", "deleteFolder", "countFolderItems", "moveItem",
                                 "renameFile", "createFolder", "validateName", "validateMoveTarget" }) do
                check(type(Manager[f]) == "function", "提供方法 " .. f)
            end
            eq(package.loaded["wdr.webdav"], nil, "manager 不 require wdr.webdav")
            eq(package.loaded["uimanager"], nil, "manager 不 require uimanager")
            eq(package.loaded["socket.http"], nil, "manager 不 require socket.http")
            eq(Manager.default_max_depth, 8, "默认最大深度为 8")
            eq(Manager.default_max_items, 2000, "默认条目上限为 2000")
    end)
    
    R.case("契约检查#16", function()
            -- 依赖缺失时不应崩溃（无 progress / 无 cache）
            local client = newClient(TREE)
            local m = Manager:new({ get_client = function() return client end })
            local ok, count = m:deleteFolder(SERVER, "books")
            eq(ok, true, "缺少 progress/cache 时删除仍成功（联动可省略）")
            eq(count, 6, "缺少 progress/cache 时计数正确")
        
            -- get_client 抛异常时应返回错误而不是崩溃
            local m_raise = Manager:new({
                get_client = function() error("boom") end,
            })
            local ok2, err2 = m_raise:deleteFile(SERVER, "a.txt")
            eq(ok2, false, "get_client 抛异常时返回 false")
            check(type(err2) == "string", "get_client 抛异常时给出错误消息")
    end)
    
    R.case("契约检查#17", function()
            -- 服务器把 "." / ".." 也列出来时不应死循环
            local trees = {
                ["loop"] = {
                    { name = ".", path = "loop", is_folder = true },
                    { name = "..", path = "", is_folder = true },
                    { name = "x.txt", path = "loop/x.txt", is_folder = false },
                },
            }
            local client = newClient(trees)
            local m = newManager({ client = client })
            local ok, count = m:deleteFolder(SERVER, "loop")
            eq(ok, true, "忽略 . 与 .. 条目，不无限递归")
            eq(count, 1, "只统计真实子项")
            eq(table.concat(client.deleted, ","), "loop/x.txt,loop", "只删除真实子项与目录自身")
    end)

    R.case("契约检查#18:client 方法抛异常", function()
            -- 客户端方法内部抛异常时，必须转成错误返回值而不是把异常抛给 UI
            local function throwingClient(method, err)
                local c = newClient()
                c[method] = function() error(err) end
                return c
            end

            local md = newManager({ client = throwingClient("delete", "socket died") })
            local ok1, err1 = md:deleteFile(SERVER, "a.txt")
            eq(ok1, false, "delete 抛异常时 deleteFile 返回 false")
            check(err1 and err1:find("Delete failed", 1, true) ~= nil,
                "delete 抛异常时带操作名前缀", tostring(err1))

            local ml = newManager({ client = throwingClient("list", "timeout") })
            local ok2, _, err2 = ml:deleteFolder(SERVER, "d")
            eq(ok2, false, "list 抛异常时 deleteFolder 返回 false")
            check(err2 and err2:find("List failed", 1, true) ~= nil,
                "list 抛异常时带操作名前缀", tostring(err2))

            local mm = newManager({ client = throwingClient("move", "broken pipe") })
            local ok3, err3 = mm:moveItem(SERVER, "a.txt", "b.txt")
            eq(ok3, false, "move 抛异常时 moveItem 返回 false")
            check(err3 and err3:find("Move failed", 1, true) ~= nil,
                "move 抛异常时带操作名前缀", tostring(err3))

            local mk = newManager({ client = throwingClient("mkdir", "no space") })
            local ok4, _, err4 = mk:createFolder(SERVER, "d", "x")
            eq(ok4, false, "mkdir 抛异常时 createFolder 返回 false")
            check(err4 and err4:find("Create folder failed", 1, true) ~= nil,
                "mkdir 抛异常时带操作名前缀", tostring(err4))
    end)

    R.case("契约检查#19:client 缺少方法", function()
            -- 客户端不完整（例如未来重构）时也要优雅失败
            local bare = {} -- 没有任何方法
            local m = newManager({ client = bare })
            local ok1, err1 = m:deleteFile(SERVER, "a.txt")
            eq(ok1, false, "缺少 delete 方法时返回 false")
            check(type(err1) == "string", "缺少 delete 方法时给出错误消息")

            local ok2, err2 = m:moveItem(SERVER, "a.txt", "b.txt")
            eq(ok2, false, "缺少 move 方法时返回 false")
            check(type(err2) == "string", "缺少 move 方法时给出错误消息")
    end)
end

local M = {}

--- run_all.lua 入口。
function M.run(T)
    R = newSuiteReport(T)
    runSuite()
    R.finish()
    return M
end

if is_standalone then
    R = newStandaloneReport()
    runSuite()
    R.finish()
end

return M
