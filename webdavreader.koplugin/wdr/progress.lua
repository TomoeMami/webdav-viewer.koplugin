-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
进度桥接层：把 KOReader 的阅读进度同步到本插件独有的 JSON。

为什么需要这层：
  * KOReader 原生把进度写在「文档 sidecar」里，而远程文件被下载到临时目录后路径会变
    （缓存被清理、换个设备、换个缓存名），sidecar 就找不到了；
  * 本插件用「服务器 + 远程路径 + 文件名」作为稳定键，把 last_xpointer / last_page /
    percent_finished 抽出来单独保存，于是换个缓存目录也能恢复进度。

进度 JSON 结构（version 1）：
{
  "version": 1,
  "files": {
    "<server_id>/<远端相对路径>": {
      "percent": 0.42,          -- 阅读百分比 (0..1)
      "xpointer": "/body/DocFragment[3]/body/div/p[12]/text().0",  -- EPUB/HTML 定位
      "page": 12,               -- PDF/图片等按页定位
      "total_pages": 300,
      "remote_path": "books/三体.txt",
      "server_name": "我的 NAS",
      "title": "三体.txt",
      "updated": 1700000000     -- 最后同步时间
    }
  }
}

@module koplugin.webdavreader.progress
--]]--

local Cache = require("wdr.cache")
local Config = require("wdr.config")
local Store = require("wdr.store")
local json = require("wdr.json")
local logger = require("logger")

local Progress = {
    store = nil,
    path = nil,
}

--- 初始化（幂等）。由 main.lua 在插件加载时调用。
-- @param json_path string|nil 不传则用 Config 默认路径
function Progress:init(json_path)
    local path = json_path or Config:getProgressPath()
    if self.store and self.path == path then
        return self
    end
    self.path = path
    -- 确保目录存在
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        Config.ensureDir(dir)
    end
    local store = Store.newProgressStore({
        path = path,
        encode = function(tbl) return json.encode(tbl) end,
        decode = function(str)
            local decoded, err = json.decode(str)
            if err then error(err) end
            return decoded
        end,
    })
    store:load()
    self.store = store
    return self
end

--- 测试用：注入自定义 progress store。
function Progress:_setStoreForTest(store, path)
    self.store = store
    self.path = path
end

--- 取远程文件的稳定键。
-- @return string "<server_id>/<相对路径>"
function Progress:getKey(server, remote_path)
    return Store.getRemoteKey(server, remote_path)
end

--- 读取某远程文件的进度记录。
-- @return table|nil
function Progress:get(server, remote_path)
    if not self.store then return nil end
    return self.store:get(self:getKey(server, remote_path))
end

--- 保存进度。
-- @param entry table 至少含 percent / xpointer / page 之一
-- @return boolean ok
function Progress:save(server, remote_path, entry)
    if not self.store then return false end
    local key = self:getKey(server, remote_path)
    local ok = self.store:set(key, entry, {
        title = Store.getRemoteFileName(remote_path),
        server_name = server and server.name or nil,
        remote_path = Store.normalizeDir(remote_path),
    })
    self.store:flushIfDirty()
    return ok
end

--- 删除进度（远程文件被删除时调用）。
function Progress:remove(server, remote_path)
    if not self.store then return false end
    local ok = self.store:remove(self:getKey(server, remote_path))
    self.store:flushIfDirty()
    return ok
end

--- 远程文件移动后，把进度键迁到新路径。
function Progress:rename(server, old_path, new_path)
    if not self.store then return false end
    local ok = self.store:rename(
        self:getKey(server, old_path),
        self:getKey(server, new_path),
        { remote_path = Store.normalizeDir(new_path) })
    self.store:flushIfDirty()
    return ok
end

--- 按服务器 id 清空其全部进度（移除服务器配置时调用）。
function Progress:removeServer(server)
    if not self.store then return 0 end
    local n = self.store:removeServer(Store.getServerId(server))
    self.store:flushIfDirty()
    return n
end

--- 列出全部进度（按更新时间倒序）。
function Progress:list()
    if not self.store then return {} end
    return self.store:list()
end

function Progress:flush()
    if not self.store then return true end
    return self.store:flushIfDirty()
end

--- 从 ReaderUI 的 doc_settings 抽取进度。
-- 兼容滚动型（xpointer）与分页型（page）两种文档。
-- @param doc_settings DocSettings
-- @param document Document|nil 可选，用于补齐总页数
-- @return table|nil
function Progress:extractFromDocSettings(doc_settings)
    if not doc_settings then return nil end
    local entry = {}

    local percent = doc_settings:readSetting("percent_finished")
    if type(percent) == "number" and percent >= 0 and percent <= 1 then
        entry.percent = percent
    end

    local xpointer = doc_settings:readSetting("last_xpointer")
    if type(xpointer) == "string" and xpointer ~= "" then
        entry.xpointer = xpointer
    end

    local page = doc_settings:readSetting("last_page")
    if type(page) == "number" and page > 0 then
        entry.page = page
    end

    local pages = doc_settings:readSetting("doc_pages")
    if type(pages) == "number" and pages > 0 then
        entry.total_pages = pages
    end

    -- cre_dom_version 必须一起保存：
    -- KOReader 的 ReaderRolling:onReadSettings 在没有 cre_dom_version 但有 last_xpointer 时，
    -- 会认为「这本书以前用旧版本打开过」，于是强制请求【最旧】的 DOM 版本
    -- （readerrolling.lua:172-184）。缓存被清理后 sidecar 不存在，若不恢复该字段，
    -- 下次打开的 DOM 版本可能和生成 xpointer 时不同，跳转会失败、表现为「打开就回到书首」。
    local dom_version = doc_settings:readSetting("cre_dom_version")
    if type(dom_version) == "number" then
        entry.cre_dom_version = dom_version
    end

    if not entry.percent and not entry.xpointer and not entry.page then
        return nil
    end
    -- 一个没有任何定位信息、且百分比为 0 的记录没有意义
    if not entry.xpointer and not entry.page and (entry.percent or 0) <= 0 then
        return nil
    end
    entry.updated = os.time()
    return entry
end

--- 把插件 JSON 里的进度写回 doc_settings，供 ReaderUI 打开时定位。
-- 必须在 ReaderUI 初始化读取 settings 之前调用（即 DocSettingsLoad 事件里）。
-- @param doc_settings DocSettings
-- @param entry table
-- @return boolean 是否写入了任何内容
function Progress:applyToDocSettings(doc_settings, entry)
    if not doc_settings or type(entry) ~= "table" then return false end
    local wrote = false
    if entry.xpointer and entry.xpointer ~= "" then
        doc_settings:saveSetting("last_xpointer", entry.xpointer)
        wrote = true
    end
    if entry.page then
        doc_settings:saveSetting("last_page", entry.page)
        wrote = true
    end
    if entry.percent then
        doc_settings:saveSetting("percent_finished", entry.percent)
        wrote = true
    end
    -- 与 xpointer 配套恢复 DOM 版本，否则可能整段进度对不上（见 extractFromDocSettings 的说明）
    if entry.cre_dom_version and entry.xpointer then
        doc_settings:saveSetting("cre_dom_version", entry.cre_dom_version)
        wrote = true
    end
    return wrote
end

--- 合并两份进度：以 updated 更新的为准，但保留双方的定位字段。
-- 用于「本地打开过但插件 JSON 里也有记录」的冲突情况。
function Progress:mergeEntries(a, b)
    if not a then return b end
    if not b then return a end
    local newer = ((a.updated or 0) >= (b.updated or 0)) and a or b
    local older = (newer == a) and b or a
    local merged = {}
    for k, v in pairs(older) do merged[k] = v end
    for k, v in pairs(newer) do merged[k] = v end
    return merged
end

--- 把进度格式化成界面展示用的短字符串。
-- @param entry table|nil
-- @return string|nil
function Progress.formatEntry(entry)
    if not entry then return nil end
    local parts = {}
    if entry.percent then
        local pct = math.floor(entry.percent * 100 + 0.5)
        if pct > 0 then
            table.insert(parts, string.format("%d%%", pct))
        end
    elseif entry.page and entry.total_pages then
        table.insert(parts, string.format("%d/%d", entry.page, entry.total_pages))
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

return Progress
