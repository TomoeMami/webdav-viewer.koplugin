--[[--
wdr/config.lua 单元测试
--]]--

local M = {}

function M.run(T, root)
    local Config = require("wdr.config")
    local LuaSettings = require("luasettings")

    io.write("\n### config\n")

    -- 每个用例前重置单例
    local function freshConfig()
        os.remove(root .. "/tmp_settings/webdavreader.lua")
        Config:_setSettingsForTest(nil)
        Config.settings = nil
        Config.servers = nil
        Config.updated = false
        return Config
    end

    T.test("validateAddress 接受 http/https", function()
        T.eq(Config.validateAddress("https://nas.example.com/dav"), true)
        T.eq(Config.validateAddress("http://192.168.1.2:8080"), true)
    end)

    T.test("validateAddress 拒绝空与非法", function()
        local ok, err = Config.validateAddress("")
        T.eq(ok, false)
        T.ok(err)

        ok, err = Config.validateAddress("nas.example.com/dav")
        T.eq(ok, false)
        T.contains(err, "http")

        ok = Config.validateAddress("ftp://x")
        T.eq(ok, false)

        ok = Config.validateAddress(nil)
        T.eq(ok, false)
    end)

    T.test("normalizeAddress 去末尾斜杠", function()
        T.eq(Config.normalizeAddress("https://a.com/dav/"), "https://a.com/dav")
        T.eq(Config.normalizeAddress("https://a.com/dav///"), "https://a.com/dav")
        T.eq(Config.normalizeAddress(" https://a.com/dav "), "https://a.com/dav")
        T.eq(Config.normalizeAddress(nil), "")
    end)

    T.test("newServer 给出完整默认值", function()
        local s = Config.newServer()
        T.eq(s.start_dir, "/")
        T.eq(s.address, "")
        T.eq(s.name, "")
        T.eq(s.verify_ssl, true)
    end)

    T.test("添加与读取服务器", function()
        freshConfig()
        local idx = Config:addServer({
            name = "NAS", address = "https://nas.local/dav",
            username = "u", password = "p",
        })
        T.eq(idx, 1)
        T.eq(Config:getServerCount(), 1)
        local s = Config:getServer(1)
        T.eq(s.name, "NAS")
        T.eq(s.address, "https://nas.local/dav")
        T.eq(s.start_dir, "/")
    end)

    T.test("getServers 返回副本不泄漏内部状态", function()
        freshConfig()
        Config:addServer({ name = "A", address = "https://a/" })
        local list = Config:getServers()
        list[1].name = "被外部改了"
        T.eq(Config:getServer(1).name, "A", "内部状态不应被修改")
    end)

    T.test("更新服务器", function()
        freshConfig()
        Config:addServer({ name = "A", address = "https://a/" })
        T.eq(Config:updateServer(1, { name = "B", address = "https://b/" }), true)
        T.eq(Config:getServer(1).name, "B")
        T.eq(Config:updateServer(9, { name = "X" }), false)
    end)

    T.test("删除服务器", function()
        freshConfig()
        Config:addServer({ name = "A", address = "https://a/" })
        Config:addServer({ name = "B", address = "https://b/" })
        Config:addServer({ name = "C", address = "https://c/" })
        T.eq(Config:removeServer(2), true)
        T.eq(Config:getServerCount(), 2)
        T.eq(Config:getServer(1).name, "A")
        T.eq(Config:getServer(2).name, "C")
        T.eq(Config:removeServer(9), false)
    end)

    T.test("删除服务器时修正默认索引", function()
        freshConfig()
        Config:addServer({ name = "A", address = "https://a/" })
        Config:addServer({ name = "B", address = "https://b/" })
        Config:addServer({ name = "C", address = "https://c/" })
        Config:setDefaultServerIndex(3)
        Config:removeServer(1) -- 默认索引应 3 -> 2
        T.eq(Config:getDefaultServerIndex(), 2)

        -- 删掉默认那个应该清空
        Config:setDefaultServerIndex(2)
        Config:removeServer(2)
        T.eq(Config:getDefaultServerIndex(), nil)
    end)

    T.test("start_dir 规范化", function()
        freshConfig()
        Config:addServer({ name = "A", address = "https://a/", start_dir = "books/" })
        T.eq(Config:getServer(1).start_dir, "/books")

        Config:addServer({ name = "B", address = "https://b/", start_dir = "//books//sub//" })
        T.eq(Config:getServer(2).start_dir, "/books/sub")

        Config:addServer({ name = "C", address = "https://c/", start_dir = "/" })
        T.eq(Config:getServer(3).start_dir, "/")

        Config:addServer({ name = "D", address = "https://d/", start_dir = "" })
        T.eq(Config:getServer(4).start_dir, "/")
    end)

    T.test("缓存容量设置", function()
        freshConfig()
        T.eq(Config:getMaxCacheMB(), Config.DEFAULT_MAX_CACHE_MB)
        Config:setMaxCacheMB(128)
        T.eq(Config:getMaxCacheMB(), 128)
    end)

    T.test("布尔开关默认值", function()
        freshConfig()
        T.eq(Config:getReturnToBrowser(), true, "默认打开阅读后返回浏览界面")
        T.eq(Config:getKeepCache(), false, "默认不保留缓存")
        Config:setReturnToBrowser(false)
        T.eq(Config:getReturnToBrowser(), false)
        Config:setKeepCache(true)
        T.eq(Config:getKeepCache(), true)
    end)

    T.test("路径派生正确", function()
        local p = Config:getProgressPath()
        T.contains(p, "webdavreader_progress.json")
        local c = Config:getCacheDir()
        T.contains(c, "webdavreader_cache")
        local s = Config:getSettingsPath()
        T.contains(s, "webdavreader.lua")
    end)

    T.test("ensureDir 递归创建", function()
        local base = root .. "/tmp_ensure/a/b/c"
        os.execute("rm -rf '" .. root .. "/tmp_ensure'")
        T.eq(Config.ensureDir(base), true)
        local lfs = require("lfs")
        T.eq(lfs.attributes(base, "mode"), "directory")
        -- 幂等
        T.eq(Config.ensureDir(base), true)
        os.execute("rm -rf '" .. root .. "/tmp_ensure'")
    end)

    T.test("ensureDir 对已存在的文件返回 false", function()
        local f = root .. "/tmp_ensure_file"
        local fh = io.open(f, "w") fh:write("x") fh:close()
        T.eq(Config.ensureDir(f), false)
        os.remove(f)
    end)

    T.test("默认值填充：缺字段的旧配置不崩溃", function()
        freshConfig()
        local fake = LuaSettings:open(root .. "/tmp_settings/legacy.lua")
        fake:saveSetting("servers", {
            { name = "只有名字" },
        })
        Config:_setSettingsForTest(fake)
        local s = Config:getServer(1)
        T.is_table(s, "应读到服务器")
        T.eq(s.name, "只有名字")
        T.eq(s.start_dir, "/", "缺失字段应补默认值")
        T.eq(s.address, "")
    end)

    T.test("空配置返回空列表", function()
        freshConfig()
        Config:_setSettingsForTest(LuaSettings:open(root .. "/tmp_settings/empty.lua"))
        T.eq(#Config:getServers(), 0)
        T.eq(Config:getServer(1), nil)
        T.eq(Config:getDefaultServerIndex(), nil)
    end)

    return M
end

return M
