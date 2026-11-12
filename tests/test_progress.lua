--[[--
wdr/progress.lua 单元测试

重点验证本插件的核心需求：
  * 进度存在插件独有的 JSON 里
  * 以「远程路径 + 文件名」为键区分
  * 缓存被清空 / 缓存路径变化后进度仍能恢复
--]]--

local M = {}

function M.run(T, root)
    local Progress = require("wdr.progress")
    local Store = require("wdr.store")
    local json = require("wdr.json")
    local Config = require("wdr.config")

    io.write("\n### progress\n")

    local server = { name = "NAS", address = "https://nas.example.com/dav" }
    local server2 = { name = "其他", address = "https://other.example.com/dav" }

    -- 每个用例用独立的进度文件
    local function freshProgress(name)
        local path = root .. "/tmp_progress/" .. (name or "p") .. ".json"
        os.execute("rm -rf '" .. root .. "/tmp_progress'")
        local dir = path:match("^(.*)/[^/]+$")
        Config.ensureDir(dir)
        Progress:init(path)
        return path
    end

    -- 假的 DocSettings
    local function fakeDocSettings(settings)
        local s = settings or {}
        return {
            data = s,
            readSetting = function(self, key, default)
                local v = self.data[key]
                if v == nil then return default end
                return v
            end,
            saveSetting = function(self, key, value)
                self.data[key] = value
            end,
        }
    end

    T.test("键格式为 serverid/远程路径", function()
        freshProgress("key")
        local key = Progress:getKey(server, "/books/三体.txt")
        T.eq(key, Store.getServerId(server) .. "/books/三体.txt")
    end)

    T.test("保存与读取进度", function()
        freshProgress("save")
        Progress:save(server, "/books/a.txt", { percent = 0.42, page = 12 })
        local e = Progress:get(server, "/books/a.txt")
        T.is_table(e, "应能读回")
        T.near(e.percent, 0.42)
        T.eq(e.page, 12)
        T.eq(e.title, "a.txt", "应自动记录文件名")
        T.eq(e.server_name, "NAS")
        T.eq(e.remote_path, "books/a.txt")
    end)

    T.test("同名文件在不同远程目录互不影响", function()
        freshProgress("distinct")
        Progress:save(server, "/books/a.txt", { percent = 0.1 })
        Progress:save(server, "/papers/a.txt", { percent = 0.9 })
        T.near(Progress:get(server, "/books/a.txt").percent, 0.1)
        T.near(Progress:get(server, "/papers/a.txt").percent, 0.9)
    end)

    T.test("同名同路径在不同服务器互不影响", function()
        freshProgress("servers")
        Progress:save(server, "/books/a.txt", { percent = 0.1 })
        Progress:save(server2, "/books/a.txt", { percent = 0.9 })
        T.near(Progress:get(server, "/books/a.txt").percent, 0.1)
        T.near(Progress:get(server2, "/books/a.txt").percent, 0.9)
    end)

    T.test("进度落盘为 JSON 且结构符合约定", function()
        local path = freshProgress("json")
        Progress:save(server, "/books/a.txt", { percent = 0.42, xpointer = "/body/x" })
        local fh = io.open(path, "r")
        T.ok(fh, "文件应存在")
        local content = fh:read("*all")
        fh:close()
        local decoded, err = json.decode(content)
        T.eq(err, nil, "应是合法 JSON")
        T.eq(decoded.version, 1)
        T.is_table(decoded.files, "files 字段")
        local key = Progress:getKey(server, "/books/a.txt")
        T.is_table(decoded.files[key], "应含该键")
        T.near(decoded.files[key].percent, 0.42)
    end)

    T.test("进度文件是插件独有的，不混用 KOReader sidecar", function()
        -- 默认路径（不注入自定义 path）应是插件专属的 webdavreader_progress.json
        local default_path = Config:getProgressPath()
        T.contains(default_path, "webdavreader_progress.json")
        T.not_contains(default_path, ".sdr", "不放在文档 sidecar 里")
        -- 自定义注入的路径同样不应落在某本书的 sidecar 目录里
        local path = freshProgress("own")
        T.not_contains(path, ".sdr")
    end)

    T.test("删除进度", function()
        freshProgress("remove")
        Progress:save(server, "/a.txt", { percent = 0.5 })
        Progress:remove(server, "/a.txt")
        T.eq(Progress:get(server, "/a.txt"), nil)
    end)

    T.test("移动后进度跟随迁移", function()
        freshProgress("rename")
        Progress:save(server, "/books/old.txt", { percent = 0.7, page = 7 })
        Progress:rename(server, "/books/old.txt", "/archive/new.txt")
        T.eq(Progress:get(server, "/books/old.txt"), nil, "旧路径应清空")
        local e = Progress:get(server, "/archive/new.txt")
        T.is_table(e, "新路径应有记录")
        T.near(e.percent, 0.7, nil, "进度应保留")
        T.eq(e.remote_path, "archive/new.txt", "元数据应更新")
    end)

    T.test("清空缓存后进度仍可读取", function()
        -- 模拟：下载 -> 记录进度 -> 清缓存 -> 重新下载到不同缓存名 -> 仍能读到进度
        local path = freshProgress("cache_recover")
        local Cache = require("wdr.cache")
        local cache_dir = "/tmp/wdr_tmp_progress_cache"
        os.execute("rm -rf '" .. cache_dir .. "'")
        Cache:setDir(cache_dir)
        Cache:ensureDir()

        local remote = "/books/三体.txt"
        local local1 = Cache:getLocalPath(server, remote)
        local fh = io.open(local1, "w") fh:write("hello") fh:close()
        Progress:save(server, remote, { percent = 0.33, xpointer = "/body/p[3]" })

        Cache:clear()
        T.eq(Cache:exists(server, remote), false, "缓存应被清空")

        local local2 = Cache:getLocalPath(server, remote)
        T.eq(local2, local1, "同名同路径缓存名稳定（便于复用）")
        local e = Progress:get(server, remote)
        T.is_table(e, "清缓存后进度应仍在")
        T.near(e.percent, 0.33)
        os.execute("rm -rf '" .. cache_dir .. "'")
    end)

    T.test("fromDocSettings 抽取 xpointer 与百分比", function()
        local ds = fakeDocSettings({
            last_xpointer = "/body/DocFragment[3]/body/div/p[12]/text().0",
            percent_finished = 0.25,
            doc_pages = 300,
        })
        local e = Progress:extractFromDocSettings(ds)
        T.is_table(e, "应抽取到记录")
        T.eq(e.xpointer, "/body/DocFragment[3]/body/div/p[12]/text().0")
        T.near(e.percent, 0.25)
        T.eq(e.total_pages, 300)
    end)

    T.test("fromDocSettings 抽取按页定位", function()
        local ds = fakeDocSettings({
            last_page = 37,
            percent_finished = 0.37,
            doc_pages = 100,
        })
        local e = Progress:extractFromDocSettings(ds)
        T.eq(e.page, 37)
        T.near(e.percent, 0.37)
        T.eq(e.total_pages, 100)
    end)

    T.test("fromDocSettings 对空 settings 返回 nil", function()
        T.eq(Progress:extractFromDocSettings(fakeDocSettings({})), nil)
        T.eq(Progress:extractFromDocSettings(nil), nil)
    end)

    T.test("fromDocSettings 忽略非法百分比", function()
        local ds = fakeDocSettings({ percent_finished = 1.5 })
        T.eq(Progress:extractFromDocSettings(ds), nil, "超范围百分比不应产生记录")

        ds = fakeDocSettings({ percent_finished = -0.1 })
        T.eq(Progress:extractFromDocSettings(ds), nil)
    end)

    T.test("fromDocSettings 拒绝仅 0% 的空记录", function()
        local ds = fakeDocSettings({ percent_finished = 0 })
        T.eq(Progress:extractFromDocSettings(ds), nil, "0% 且无定位信息无意义")
    end)

    T.test("applyToDocSettings 写回定位信息", function()
        local ds = fakeDocSettings({})
        local wrote = Progress:applyToDocSettings(ds, {
            xpointer = "/body/p[5]",
            page = 9,
            percent = 0.09,
        })
        T.eq(wrote, true)
        T.eq(ds.data.last_xpointer, "/body/p[5]")
        T.eq(ds.data.last_page, 9)
        T.near(ds.data.percent_finished, 0.09)
    end)

    T.test("applyToDocSettings 空记录不写入", function()
        local ds = fakeDocSettings({})
        T.eq(Progress:applyToDocSettings(ds, {}), false)
        T.eq(ds.data.last_xpointer, nil)
    end)

    T.test("进度往返：抽取 -> 保存 -> 写回 得到一致定位", function()
        freshProgress("roundtrip")
        local src = fakeDocSettings({
            last_xpointer = "/body/DocFragment[2]/body/p[7]/text().3",
            percent_finished = 0.51,
            doc_pages = 200,
        })
        local entry = Progress:extractFromDocSettings(src)
        Progress:save(server, "/books/rt.epub", entry)

        local stored = Progress:get(server, "/books/rt.epub")
        local dst = fakeDocSettings({})
        Progress:applyToDocSettings(dst, stored)

        T.eq(dst.data.last_xpointer, src.data.last_xpointer, "xpointer 应完全一致")
        T.near(dst.data.percent_finished, 0.51)
    end)

    T.test("mergeEntries 以较新者为准并补充缺字段", function()
        local a = { percent = 0.5, updated = 100 }
        local b = { percent = 0.6, xpointer = "/body/x", updated = 200 }
        local merged = Progress:mergeEntries(a, b)
        T.near(merged.percent, 0.6, nil, "取较新的百分比")
        T.eq(merged.xpointer, "/body/x", "保留定位信息")
    end)

    T.test("mergeEntries 处理 nil", function()
        local a = { percent = 0.5 }
        T.eq(Progress:mergeEntries(nil, a), a)
        T.eq(Progress:mergeEntries(a, nil), a)
        T.eq(Progress:mergeEntries(nil, nil), nil)
    end)

    T.test("formatEntry 生成展示字符串", function()
        T.eq(Progress.formatEntry(nil), nil)
        T.eq(Progress.formatEntry({ percent = 0.423 }), "42%")
        T.eq(Progress.formatEntry({ percent = 1 }), "100%")
        T.eq(Progress.formatEntry({ percent = 0.004 }), nil, "太小不显示")
        T.eq(Progress.formatEntry({ page = 12, total_pages = 300 }), "12/300")
        T.eq(Progress.formatEntry({}), nil)
    end)

    T.test("removeServer 清空该服务器全部进度", function()
        freshProgress("rm_server")
        Progress:save(server, "/a.txt", { percent = 0.1 })
        Progress:save(server, "/b.txt", { percent = 0.2 })
        Progress:save(server2, "/c.txt", { percent = 0.3 })
        local n = Progress:removeServer(server)
        T.eq(n, 2)
        T.eq(Progress:get(server, "/a.txt"), nil)
        T.eq(Progress:get(server2, "/c.txt") ~= nil, true, "其他服务器保留")
    end)

    T.test("list 返回全部记录按更新时间倒序", function()
        freshProgress("list")
        Progress:save(server, "/a.txt", { percent = 0.1, updated = 100 })
        Progress:save(server, "/b.txt", { percent = 0.2, updated = 300 })
        local list = Progress:list()
        T.eq(#list, 2)
        T.contains(list[1].entry.remote_path or "", "b.txt")
    end)

    T.test("未初始化时方法安全返回", function()
        Progress:init("/tmp/wdr_tmp_progress/none.json")
        local saved = Progress.store
        Progress.store = nil
        T.eq(Progress:get(server, "/x"), nil)
        T.eq(Progress:save(server, "/x", { percent = 1 }), false)
        T.eq(#Progress:list(), 0, "未初始化时 list 为空")
        Progress.store = saved
    end)

    return M
end

return M
