-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
临时缓存管理

设计要点：
  * 远程文件下载到一个扁平化的临时目录（不建目录树），文件名 = 12 位哈希 + 可读名 + 扩展名，
    保证不同服务器 / 不同目录的同名文件互不覆盖；
  * 缓存目录可被整体清理，不影响进度（进度在独立 JSON 里）；
  * 有容量上限，超出后按「最后访问时间」淘汰。

@module koplugin.webdavreader.cache
--]]--

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Store = require("wdr.store")

local Cache = {
    dir = nil,
    -- 记录最近访问时间（内存态，落盘意义不大；用文件 atime 不可靠）
    access_times = {},
}

function Cache:setDir(dir)
    self.dir = dir
    return self
end

function Cache:getDir()
    return self.dir
end

--- 确保缓存目录存在。
function Cache:ensureDir()
    if not self.dir then return false end
    local mode = lfs.attributes(self.dir, "mode")
    if mode == "directory" then return true end
    if mode then return false end
    -- 递归创建父目录
    local parent = self.dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= self.dir then
        if lfs.attributes(parent, "mode") ~= "directory" then
            Cache._mkdirs(parent)
        end
    end
    local ok = lfs.mkdir(self.dir)
    if ok or lfs.attributes(self.dir, "mode") == "directory" then
        return true
    end
    logger.warn("webdavreader: 无法创建缓存目录", self.dir)
    return false
end

function Cache._mkdirs(dir)
    local mode = lfs.attributes(dir, "mode")
    if mode == "directory" then return true end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= dir then
        Cache._mkdirs(parent)
    end
    lfs.mkdir(dir)
    return lfs.attributes(dir, "mode") == "directory"
end

--- 该远程文件对应的本地缓存路径。
-- @param server table
-- @param remote_path string
-- @return string|nil
function Cache:getLocalPath(server, remote_path)
    if not self.dir then return nil end
    return self.dir .. "/" .. Store.getCacheFileName(server, remote_path)
end

--- 本地缓存是否存在（不论新鲜度）。
function Cache:exists(server, remote_path)
    local p = self:getLocalPath(server, remote_path)
    if not p then return false end
    return lfs.attributes(p, "mode") == "file"
end

--- 缓存是否可直接使用（存在且大小与远端一致）。
-- 远端未提供大小时，退化为「存在即认为可用」由调用方决定，这里返回 false 以便重新校验。
-- @param server table
-- @param remote_path string
-- @param remote_size number|nil
-- @return boolean
function Cache:isFresh(server, remote_path, remote_size, remote_mtime)
    local p = self:getLocalPath(server, remote_path)
    if not p then return false end
    local size = lfs.attributes(p, "size")
    if not size then return false end

    -- 下载时记录的远端修改时间（内存态）。远端文件被「同名同大小」地改过时
    -- （编辑后重新上传的 txt/epub 很常见），只比大小会继续用旧缓存。
    local known_mtime = self.remote_mtimes and self.remote_mtimes[p]
    if remote_mtime and known_mtime then
        if math.abs(remote_mtime - known_mtime) > 1 then
            return false
        end
        -- 时间也对得上，再看大小
        if not remote_size then return size > 0 end
        return size == remote_size
    end

    if not remote_size then
        -- 远端没给大小：存在就认为可用（避免每次重复下载大文件）
        return size > 0
    end
    return size == remote_size
end

--- 记录某文件下载时对应的远端修改时间与大小，供 isFresh 做更可靠的比较。
function Cache:markDownloaded(server, remote_path, remote_size, remote_mtime)
    local p = self:getLocalPath(server, remote_path)
    if not p then return end
    self.remote_mtimes = self.remote_mtimes or {}
    if remote_mtime then
        self.remote_mtimes[p] = remote_mtime
    else
        self.remote_mtimes[p] = nil
    end
end

--- 标记某文件的缓存失效（删除本地副本）。
function Cache:invalidate(server, remote_path)
    local p = self:getLocalPath(server, remote_path)
    if p then
        self.access_times[p] = nil
        os.remove(p)
        -- 顺带清理 KOReader 生成的 sidecar 目录（若 sidecar 存在于此），避免残留配置
        local sidecar = p .. ".sdr"
        if lfs.attributes(sidecar, "mode") == "directory" then
            Cache._rmrf(sidecar)
        end
    end
end

--- 记录一次访问（用于 LRU 淘汰）。
function Cache:touch(server, remote_path)
    local p = self:getLocalPath(server, remote_path)
    if p then
        self.access_times[p] = os.time()
    end
end

function Cache._rmrf(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                Cache._rmrf(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

--- 统计缓存总大小（字节）。
function Cache:sizeBytes()
    local total = 0
    if not self.dir then return 0 end
    local ok, iter, state = pcall(lfs.dir, self.dir)
    if not ok or not iter then return 0 end
    for entry in iter, state do
        if entry ~= "." and entry ~= ".." then
            local full = self.dir .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "file" then
                total = total + (lfs.attributes(full, "size") or 0)
            elseif mode == "directory" then
                total = total + Cache._dirSize(full)
            end
        end
    end
    return total
end

function Cache._dirSize(dir)
    local total = 0
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok or not iter then return 0 end
    for entry in iter, state do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "file" then
                total = total + (lfs.attributes(full, "size") or 0)
            elseif mode == "directory" then
                total = total + Cache._dirSize(full)
            end
        end
    end
    return total
end

--- 列出缓存条目（用于设置界面展示）。
-- @return array of { name=, size=, mtime=, path= }
function Cache:listEntries()
    local out = {}
    if not self.dir then return out end
    local ok, iter, state = pcall(lfs.dir, self.dir)
    if not ok or not iter then return out end
    for entry in iter, state do
        if entry ~= "." and entry ~= ".." then
            local full = self.dir .. "/" .. entry
            if lfs.attributes(full, "mode") == "file" then
                table.insert(out, {
                    name = entry,
                    path = full,
                    size = lfs.attributes(full, "size") or 0,
                    mtime = lfs.attributes(full, "modification") or 0,
                })
            end
        end
    end
    table.sort(out, function(a, b) return a.mtime > b.mtime end)
    return out
end

--- 超过上限时淘汰最旧的文件。
-- @param max_mb number
-- @return number 删除的字节数
function Cache:prune(max_mb)
    if not self.dir or not max_mb or max_mb <= 0 then return 0 end
    local limit = max_mb * 1024 * 1024
    local total = self:sizeBytes()
    if total <= limit then return 0 end
    local entries = self:listEntries()
    -- 最旧的先删；把本次会话访问过的当作「最新」以保护正在阅读的文件
    table.sort(entries, function(a, b)
        local ta = self.access_times[a.path] or a.mtime
        local tb = self.access_times[b.path] or b.mtime
        return ta < tb
    end)
    local freed = 0
    for _, e in ipairs(entries) do
        if total - freed <= limit then break end
        -- 保护最近 30 分钟内访问过的（可能是当前正在阅读的书）
        local touched = self.access_times[e.path]
        if not touched or os.time() - touched > 1800 then
            os.remove(e.path)
            freed = freed + e.size
        end
    end
    if freed > 0 then
        logger.info("webdavreader: 缓存清理释放字节数", freed)
    end
    return freed
end

--- 清空缓存目录（保留目录本身）。
-- @return boolean ok, number freed_bytes
function Cache:clear()
    if not self.dir then return false, 0 end
    local before = self:sizeBytes()
    local ok, iter, state = pcall(lfs.dir, self.dir)
    if ok and iter then
        local names = {}
        for entry in iter, state do
            if entry ~= "." and entry ~= ".." then
                table.insert(names, entry)
            end
        end
        for _, name in ipairs(names) do
            Cache._rmrf(self.dir .. "/" .. name)
        end
    end
    self.access_times = {}
    return true, before
end

return Cache
