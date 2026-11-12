-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
WebDAV 远程读取插件 —— 纯逻辑层：进度存储 / 远程路径键 / 临时缓存 / 文件名清理

本文件不依赖 KOReader 的 UI，只依赖标准 Lua 5.1 + ffi/util（KOReader 内部模块），
因此可以在桌面 Lua 环境下用桩件单测（见 tests/）。

进度记录以「远程路径 + 文件名」为键（remote key）：
    <server_id>/<远端目录>/<文件名>
例如：
    work/books/三体.txt
其中 server_id 由服务器地址派生的短哈希 + 名字构成，避免不同服务器同名路径撞车。

@module koplugin.webdavreader.store
--]]--

local md5 = require("ffi/sha2").md5

local Store = {}

--- 计算字符串的稳定短哈希（用于服务器 ID、缓存文件名）。
-- @param s string
-- @return string 十六进制，长度 12
function Store.shortHash(s)
    local ok, hex = pcall(md5, s or "")
    if ok and type(hex) == "string" and #hex >= 12 then
        return hex:sub(1, 12)
    end
    -- 退化实现：FNV-1a 的乘法累加变体（Lua 5.1 没有位运算，用乘法代替异或混合）
    local h = 2166136261
    local s2 = s or ""
    for i = 1, #s2 do
        h = (h * 31 + s2:byte(i) * 131) % 2147483647
    end
    return string.format("%08x%04x", h, #s2 % 65536)
end

--- 生成一个服务器的稳定标识。
-- 用「地址」而不是「名字」来参与哈希，改名不会让已有进度失效。
-- @param server table 需含 address
-- @return string
function Store.getServerId(server)
    if not server then return "unknown" end
    local addr = server.address or ""
    return Store.shortHash(addr)
end

--- 规范化目录路径：去掉首尾多余斜杠、压缩重复斜杠。
-- @param path string|nil
-- @return string 以名字结尾的相对路径，根目录返回 ""
function Store.normalizeDir(path)
    if not path then return "" end
    path = tostring(path):gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    return path
end

--- 由服务器与远程路径生成进度记录的键。
-- @param server table 服务器配置（用 address 派生 id）
-- @param remote_path string 远端文件路径，可带前导斜杠
-- @return string 形如 "<server_id>/books/a.txt"
function Store.getRemoteKey(server, remote_path)
    local dir = Store.normalizeDir(remote_path)
    return Store.getServerId(server) .. "/" .. dir
end

--- 拆分键为服务器 id 与相对路径。
-- @param key string
-- @return string server_id, string rel_path
function Store.splitRemoteKey(key)
    if not key then return nil, nil end
    local sid, rel = tostring(key):match("^([^/]*)/(.*)$")
    if not sid then return nil, nil end
    return sid, rel
end

--- 从远程路径取出文件名。
function Store.getRemoteFileName(remote_path)
    if not remote_path then return "" end
    return tostring(remote_path):match("([^/]+)$") or ""
end

--- 从远程路径取出所在目录（无前导斜杠）。
function Store.getRemoteDir(remote_path)
    local dir = Store.normalizeDir(remote_path)
    return dir:match("^(.*)/[^/]*$") or ""
end

--- 拼接远程路径（不做编码，仅归一化）。
-- @param dir string|nil 目录
-- @param name string 文件名或子目录名
function Store.joinRemotePath(dir, name)
    local d = Store.normalizeDir(dir)
    name = Store.normalizeDir(name)
    if d == "" then return name end
    if name == "" then return d end
    return d .. "/" .. name
end

--- 把远程路径转成本地缓存文件名（扁平化，避免在缓存目录里建目录树）。
-- 同时保留扩展名，方便 DocumentRegistry 识别文档类型。
-- @param server table
-- @param remote_path string
-- @return string 本地文件名（不含目录）
function Store.getCacheFileName(server, remote_path)
    local key = Store.getRemoteKey(server, remote_path)
    local name = Store.getRemoteFileName(remote_path)
    -- 扩展名保留（含点），其余字符只保留安全字符
    local base, ext = name:match("^(.*)%.([%w]+)$")
    if not base then
        base, ext = name, nil
    end
    base = base:gsub("[^%w%-_%.]", "_")
    if #base > 60 then
        -- 长名字截断，但保留哈希避免冲突
        base = base:sub(1, 48) .. "-" .. Store.shortHash(name)
    end
    local safe_ext = ext and ext:gsub("[^%w]", "") or nil
    local hash = Store.shortHash(key)
    if safe_ext and safe_ext ~= "" then
        -- 小写扩展名，KOReader 的 provider 查表通常按小写
        return hash .. "-" .. base .. "." .. safe_ext:lower()
    end
    return hash .. "-" .. base
end

--- 把本地缓存文件名反解出 server_id（无法可靠反解出原始路径，仅用于清理）。
function Store.getServerIdFromCacheName(cache_name)
    return (tostring(cache_name or ""):match("^(%x+)"))
end

-- ---------------------------------------------------------------------------
-- 进度存储
-- ---------------------------------------------------------------------------

local ProgressStore = {}
ProgressStore.__index = ProgressStore

--- 创建进度存储实例。
-- @param opts table { path = "<json 文件路径>", readfile = fn(path)->string|nil,
--                     writefile = fn(path, content), mkdir = fn(path),
--                     encode = fn(table)->string, decode = fn(string)->table|nil }
-- @return ProgressStore
function Store.newProgressStore(opts)
    opts = opts or {}
    local self = setmetatable({}, ProgressStore)
    self.path = opts.path
    -- 允许注入依赖，便于在桌面环境下单测
    self._read = opts.readfile or function(path)
        local fh = io.open(path, "r")
        if not fh then return nil end
        local content = fh:read("*all")
        fh:close()
        return content
    end
    self._write = opts.writefile or function(path, content)
        local fh, err = io.open(path, "w")
        if not fh then return nil, err end
        fh:write(content)
        fh:close()
        return true
    end
    self._encode = opts.encode
    self._decode = opts.decode
    self.data = nil
    self.dirty = false
    return self
end

--- 校准内部使用的 JSON 编解码器（延迟注入，便于先建实例后加载依赖）。
function ProgressStore:setCodec(encode, decode)
    self._encode = encode
    self._decode = decode
end

--- 懒加载数据文件。
function ProgressStore:load()
    if self.data ~= nil then return true end
    self.data = { version = 1, files = {} }
    local content = self._read(self.path)
    if not content or content == "" then
        return true
    end
    if not self._decode then
        -- 没有解码器时不覆盖磁盘内容，保持空表但标记为「不可写」
        self.data = { version = 1, files = {} }
        return false
    end
    local ok, decoded = pcall(self._decode, content)
    if not ok or type(decoded) ~= "table" then
        -- 文件损坏：备份原文件后从空表开始，避免用户进度被静默清空
        self:_backupCorrupt(content)
        return false
    end
    decoded.version = decoded.version or 1
    decoded.files = decoded.files or {}
    self.data = decoded
    return true
end

function ProgressStore:_backupCorrupt(content)
    if not self.path or not content then return end
    local backup = self.path .. ".corrupt-" .. os.date("%Y%m%d%H%M%S")
    pcall(self._write, backup, content)
end

--- 读取某远程文件的进度。
-- @param key string Store.getRemoteKey 的结果
-- @return table|nil { percent, xpointer, page, total_pages, updated, title, size }
function ProgressStore:get(key)
    self:load()
    return self.data.files[key]
end

--- 写入某远程文件的进度。
-- @param key string
-- @param entry table 进度内容（会被浅拷贝）
-- @param opts table|nil { title, server_name, remote_path }
-- @return boolean
function ProgressStore:set(key, entry, opts)
    self:load()
    opts = opts or {}
    local merged = {}
    local old = self.data.files[key] or {}
    for k, v in pairs(old) do merged[k] = v end
    for k, v in pairs(entry or {}) do merged[k] = v end
    merged.updated = merged.updated or os.time()
    if opts.title then merged.title = opts.title end
    if opts.server_name then merged.server_name = opts.server_name end
    if opts.remote_path then merged.remote_path = opts.remote_path end
    self.data.files[key] = merged
    self.dirty = true
    return true
end

--- 删除进度记录（用于远程文件删除/移动后清理）。
function ProgressStore:remove(key)
    self:load()
    if self.data.files[key] ~= nil then
        self.data.files[key] = nil
        self.dirty = true
        return true
    end
    return false
end

--- 重命名进度键（用于远程移动文件）。
-- @param old_key string
-- @param new_key string
-- @param opts table|nil { remote_path }
-- @return boolean
function ProgressStore:rename(old_key, new_key, opts)
    self:load()
    local entry = self.data.files[old_key]
    if not entry then return false end
    self.data.files[old_key] = nil
    entry.updated = os.time()
    if opts and opts.remote_path then entry.remote_path = opts.remote_path end
    self.data.files[new_key] = entry
    self.dirty = true
    return true
end

--- 删除所有属于某服务器的记录（用于移除服务器配置）。
function ProgressStore:removeServer(server_id)
    self:load()
    local n = 0
    for key in pairs(self.data.files) do
        local sid = Store.splitRemoteKey(key)
        if sid == server_id then
            self.data.files[key] = nil
            n = n + 1
        end
    end
    if n > 0 then self.dirty = true end
    return n
end

--- 列出全部记录（返回副本，按更新时间倒序）。
-- @return table array of { key=..., entry=... }
function ProgressStore:list()
    self:load()
    local out = {}
    for key, entry in pairs(self.data.files) do
        table.insert(out, { key = key, entry = entry })
    end
    table.sort(out, function(a, b)
        return (a.entry.updated or 0) > (b.entry.updated or 0)
    end)
    return out
end

--- 序列化并落盘。
-- @return boolean, string|nil err
function ProgressStore:flush()
    if not self.path then return false, "no path" end
    if not self._encode then return false, "no encoder" end
    local ok, content = pcall(self._encode, self.data)
    if not ok then return false, content end
    local wok, err = self._write(self.path, content)
    if not wok then return false, err end
    self.dirty = false
    return true
end

--- 只有真的改过才落盘。
function ProgressStore:flushIfDirty()
    if self.dirty then
        return self:flush()
    end
    return true
end

Store.ProgressStore = ProgressStore

return Store
