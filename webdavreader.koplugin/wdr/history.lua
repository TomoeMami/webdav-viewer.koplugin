-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
WebDAV 远程读取插件 —— 移动位置历史记录（数据层）

为什么需要这层：
  用户经常在同一个服务器的几个目录之间来回跳（例如 /books、/books/done、
  /papers/2024）。每次打开浏览器都从 start_dir 或根目录开始，要一层层点回去。
  这里按「服务器 -> 最近用过的目录」记录一份 MRU 列表，界面把它放在目录列表
  最前面，一键回到常去的地方。

设计约束：
  * 纯逻辑，不 require UI；所有错误用返回值表达，绝不抛错；
  * 一个服务器最多保留 DEFAULT_LIMIT 条，超出淘汰最旧的一条（LRU）；
  * 按服务器隔离，键用 Store.getServerId(server)（地址派生），改名不丢历史；
  * 落盘走 Store.newJsonStore（懒加载 / dirty / 损坏备份语义与进度一致）；
  * Lua 5.1 语法（无 goto、无位运算）；所有 io.open 都成对 close。

历史 JSON 结构（version 1，与 wdr/progress.lua 的 JSON 各自独立）：
{
  "version": 1,
  "servers": {
    "<server_id>": [
      { "dir": "books/done", "used": 1700000000, "count": 3 },
      { "dir": "",           "used": 1699999000, "count": 1 }
    ]
  }
}
  dir   : 归一化后的相对目录（"" 表示根目录，是合法且有价值的一条记录）
  used  : 最后一次使用的时间（os.time() 秒）
  count : 累计使用次数（>= 1）

@module koplugin.webdavreader.history
--]]--

local Config = require("wdr.config")
local Store = require("wdr.store")
local json = require("wdr.json")

-- gettext 在桌面 Lua 单测环境下不存在，退化为恒等函数（与 manager.lua 一致）。
local _ = function(s) return s end
local ok_gettext, gettext = pcall(require, "gettext")
if ok_gettext and type(gettext) == "function" then
    _ = gettext
end

local History = {
    store = nil,
    path = nil,
    -- 每个服务器最多保留的历史条数
    DEFAULT_LIMIT = 20,
}

--- 默认（空）历史文档。每次都是新 table，避免实例之间共享。
local function defaultData()
    return { version = 1, servers = {} }
end

--- 把 "次" 的文案渲染出来。KOReader 的 ffi/util.template 认 %1，桌面桩件只认 $1，
-- 因此两条路都走一遍，最后还有纯 gsub 兜底，保证任何环境都能拿到次数。
-- @param count number
-- @return string
local function formatTimes(count)
    local template = _("%1 次")
    local rendered
    local ok_util, ffiUtil = pcall(require, "ffi/util")
    if ok_util and type(ffiUtil) == "table" and type(ffiUtil.template) == "function" then
        local ok_tpl, out = pcall(ffiUtil.template, template, count)
        if ok_tpl and type(out) == "string" then
            rendered = out
        end
    end
    if not rendered or rendered:find("%1", 1, true) then
        rendered = tostring(template):gsub("%%1", tostring(count))
    end
    return rendered
end

--- 初始化（幂等）。由 main.lua 在插件加载时调用。
-- path 不变时直接复用现有 store，不重新读盘。
-- @param json_path string|nil 不传则用 Config:getHistoryPath()
-- @return History 自身
function History:init(json_path)
    local path = json_path or Config:getHistoryPath()
    if self.store and self.path == path then
        return self
    end
    self.path = path
    -- 确保目录存在（与 progress.lua 同样的推导方式）
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        Config.ensureDir(dir)
    end
    local store = Store.newJsonStore({
        path = path,
        default_data = defaultData,
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

--- 测试用：注入自定义 store（并用 path 参与 init 的幂等判断）。
-- @param store JsonStore|nil
-- @param path string|nil
function History:_setStoreForTest(store, path)
    self.store = store
    self.path = path
    return self
end

--- 测试用：注入时钟，避免依赖 os.time() 的秒级粒度。
-- @param fn function|nil -> number
function History:_setNowForTest(fn)
    self._now = fn
end

--- 当前时间戳。
function History:_nowTime()
    if type(self._now) == "function" then
        local ok, t = pcall(self._now)
        if ok and type(t) == "number" then return t end
    end
    return os.time()
end

--- 取历史文档并保证结构可用（version / servers 缺了就地补上）。
-- @return table|nil 未初始化时返回 nil
function History:_getData()
    if not self.store then return nil end
    local data = self.store:getData()
    if type(data) ~= "table" then
        data = self.store:setData(defaultData())
    end
    if tonumber(data.version) == nil then
        data.version = 1
        self.store:markDirty()
    end
    if type(data.servers) ~= "table" then
        data.servers = {}
        self.store:markDirty()
    end
    return data
end

--- 某服务器的记录数组（不存在时就地创建）。
-- @param data table 历史文档
-- @param sid string 服务器 id
-- @return table 记录数组
function History:_bucket(data, sid)
    local list = data.servers[sid]
    if type(list) ~= "table" then
        list = {}
        data.servers[sid] = list
    end
    return list
end

--- 记录一次「进入某目录」。
-- 同一目录再次 add 时只更新 used 与 count，并提到最前（MRU）。
-- @param server table 服务器配置（用 address 派生 id）
-- @param dir string|nil 相对目录，允许 ""（根目录）、允许带前导/尾随斜杠
-- @return boolean ok, table|nil entry, string|nil err
--   成功时 entry 是归一化后的记录 { dir=, used=, count= }
function History:add(server, dir)
    if not self.store then
        return false, nil, "not initialized"
    end
    local data = self:_getData()
    if not data then
        return false, nil, "not initialized"
    end
    local norm = Store.normalizeDir(dir)
    local sid = Store.getServerId(server)
    local list = self:_bucket(data, sid)
    local now = self:_nowTime()

    -- 找同目录的旧记录：有就更新 used / count，并移到数组首位
    local entry, found
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" and Store.normalizeDir(e.dir) == norm then
            entry, found = e, i
            break
        end
    end
    if entry then
        entry.dir = norm
        entry.used = now
        entry.count = (tonumber(entry.count) or 0) + 1
        table.remove(list, found)
    else
        entry = { dir = norm, used = now, count = 1 }
    end
    table.insert(list, 1, entry)

    -- 超过上限时从尾部（最旧）淘汰
    local limit = tonumber(self.DEFAULT_LIMIT) or 20
    while #list > limit do
        table.remove(list, #list)
    end

    self.store:markDirty()
    local ok, err = self.store:flush()
    if not ok then
        -- 内存里的记录仍然有效，只是没落盘；把原因交给调用方决定是否提示
        return false, entry, err or "flush failed"
    end
    return true, entry, nil
end

--- 列出某服务器的历史目录（按 used 倒序，最近用的在前）。
-- 为兼容两种调用风格，本方法同时接受点号与冒号调用：
--     History.list(server, limit)      -- main.lua / browser.lua 使用点号
--     History:list(server, limit)      -- 单测与内部使用冒号
-- @param server table|nil 服务器配置；nil/未知服务器返回空数组
-- @param limit number|nil 最多返回条数，默认 DEFAULT_LIMIT
-- @return table array of { dir=, used=, count= }（ipairs 可遍历，永不为 nil）
function History.list(a, b, c)
    -- 第一个参数是模块本身（History:list）还是 server 配置（History.list(server)）
    local self, server, limit
    if a == History then
        self, server, limit = a, b, c
    else
        self, server, limit = History, a, b
    end

    local out = {}
    if not self.store or not server then return out end
    local data = self:_getData()
    if not data then return out end
    local sid = Store.getServerId(server)
    local list = data.servers[sid]
    if type(list) ~= "table" then return out end

    local max = tonumber(limit) or tonumber(self.DEFAULT_LIMIT) or 20
    max = math.floor(max)
    if max <= 0 then return out end

    -- order 保留磁盘数组中的位置：used 相同（同一秒内多次 add）时按 MRU 顺序排，
    -- 这样即使时间戳分辨率只有 1 秒，结果也是确定的。
    local items = {}
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" then
            items[#items + 1] = {
                order = i,
                dir = Store.normalizeDir(e.dir),
                used = tonumber(e.used) or 0,
                count = tonumber(e.count) or 1,
            }
        end
    end
    table.sort(items, function(x, y)
        if x.used ~= y.used then return x.used > y.used end
        return x.order < y.order
    end)

    for i = 1, #items do
        if #out >= max then break end
        local it = items[i]
        out[#out + 1] = { dir = it.dir, used = it.used, count = it.count }
    end
    return out
end

--- 删除某服务器下的一条历史目录。
-- @param server table
-- @param dir string|nil
-- @return boolean 是否真的删到了记录
function History:remove(server, dir)
    if not self.store then return false end
    local data = self:_getData()
    if not data then return false end
    local sid = Store.getServerId(server)
    local list = data.servers[sid]
    if type(list) ~= "table" then return false end
    local norm = Store.normalizeDir(dir)

    local removed = false
    -- 倒序遍历，删除时下标不受影响
    for i = #list, 1, -1 do
        local e = list[i]
        if type(e) == "table" and Store.normalizeDir(e.dir) == norm then
            table.remove(list, i)
            removed = true
        end
    end
    if not removed then return false end
    if #list == 0 then
        data.servers[sid] = nil
    end
    self.store:markDirty()
    self.store:flushIfDirty()
    return true
end

--- 清空历史。
-- @param server table|nil 传服务器则只清该服务器；nil 表示清空全部服务器
-- @return number 删除的记录条数
function History:clear(server)
    if not self.store then return 0 end
    local data = self:_getData()
    if not data then return 0 end

    local n = 0
    if server == nil then
        -- 不用 "_" 当占位变量：本文件顶部 local _ = gettext，遮蔽后同作用域的 _(...) 会崩
        for srv_id, list in pairs(data.servers) do
            if type(list) == "table" then
                n = n + #list
            end
        end
        data.servers = {}
    else
        local sid = Store.getServerId(server)
        local list = data.servers[sid]
        if type(list) == "table" then
            n = #list
        end
        data.servers[sid] = nil
    end
    if n > 0 then
        self.store:markDirty()
        self.store:flushIfDirty()
    end
    return n
end

--- 把内存中的历史落盘（只在 dirty 时写）。
-- @return boolean ok, string|nil err
function History:flush()
    if not self.store then return true end
    return self.store:flushIfDirty()
end

--- 当前历史 JSON 的路径（未初始化时为 nil）。
-- @return string|nil
function History:getPath()
    return self.path
end

--- 纯函数：把历史目录格式化成展示用文案。
-- @param server table|nil 预留：将来可能按服务器定制显示（本实现不使用）
-- @param dir string|nil 相对目录
-- @return string 根目录返回 "/"，其余返回 "/"..dir（不带尾斜杠）
function History.formatDir(server, dir)
    local norm = Store.normalizeDir(dir)
    if norm == "" then return "/" end
    return "/" .. norm
end

--- 纯函数：把一条历史记录格式化成菜单项文案。
-- count<=1 时不显示次数；count 用 _() 包裹（gettext 缺失时退化为原文）。
-- @param entry table|nil { dir=, used=, count= }
-- @return string 例如 "/books/done   3 次"；空记录返回 ""
function History.formatLabel(entry)
    if type(entry) ~= "table" then return "" end
    local label = History.formatDir(nil, entry.dir)
    local count = tonumber(entry.count) or 1
    if count > 1 then
        label = label .. "   " .. formatTimes(count)
    end
    return label
end

return History
