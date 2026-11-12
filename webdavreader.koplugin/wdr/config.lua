-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
服务器配置存储（多服务器）

落盘位置：<settings_dir>/webdavreader.lua（LuaSettings 格式，KOReader 惯例）
进度 JSON 与缓存目录也由本模块集中给出路径，避免各处硬编码。

@module koplugin.webdavreader.config
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Config = {
    settings = nil,
    servers = nil,
    updated = false,
    SETTINGS_FILE = "webdavreader.lua",
    PROGRESS_FILE = "webdavreader_progress.json",
    HISTORY_FILE = "webdavreader_history.json",
    CACHE_DIRNAME = "webdavreader_cache",
    DEFAULT_MAX_CACHE_MB = 256,
}

--- 默认服务器配置模板。
-- @return table
function Config.newServer()
    return {
        name = "",
        address = "",
        username = "",
        password = "",
        start_dir = "/",
        verify_ssl = true,
    }
end

--- 补齐服务器字段（读取旧配置时兜底）。
local function normalizeServer(server)
    local s = Config.newServer()
    if type(server) == "table" then
        for k, v in pairs(server) do
            s[k] = v
        end
    end
    s.start_dir = s.start_dir or "/"
    if s.start_dir ~= "/" then
        -- 统一成 /xxx 形式：压缩重复斜杠、去掉末尾斜杠
        local cleaned = s.start_dir:gsub("^/+", ""):gsub("/+$", ""):gsub("//+", "/")
        s.start_dir = cleaned == "" and "/" or ("/" .. cleaned)
    end
    return s
end

--- 浅拷贝一个 table（避免把内部状态暴露给调用方）。
local function shallowCopy(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

function Config:getSettingsPath()
    return DataStorage:getSettingsDir() .. "/" .. self.SETTINGS_FILE
end

--- 临时缓存目录（放在 KOReader data 目录下，随其生命周期）。
function Config:getCacheDir()
    return DataStorage:getDataDir() .. "/" .. self.CACHE_DIRNAME
end

--- 进度 JSON 路径。放在 settings 目录，便于用户备份。
function Config:getProgressPath()
    return DataStorage:getSettingsDir() .. "/" .. self.PROGRESS_FILE
end

--- 移动位置历史 JSON 路径。与进度文件同目录（settings），便于用户一并备份。
function Config:getHistoryPath()
    return DataStorage:getSettingsDir() .. "/" .. self.HISTORY_FILE
end

function Config:load()
    if self.servers then return self end
    -- 已注入 settings（测试或外部宿主）时直接复用，不重新打开文件
    local loaded = self.settings
    if not loaded then
        local ok, opened = pcall(function()
            return LuaSettings:open(self:getSettingsPath())
        end)
        if ok and opened then
            loaded = opened
        else
            logger.warn("webdavreader: 无法打开配置文件，使用空配置：", opened)
        end
    end
    if not loaded then
        self.settings = nil
        self.servers = {}
        return self
    end
    self.settings = loaded
    local list = loaded:readSetting("servers", {})
    self.servers = {}
    if type(list) == "table" then
        for i, s in ipairs(list) do
            self.servers[i] = normalizeServer(s)
        end
    end
    return self
end

--- 返回服务器列表的浅拷贝（调用方可安全遍历与读取）。
function Config:getServers()
    self:load()
    local out = {}
    for i, s in ipairs(self.servers) do
        out[i] = shallowCopy(s)
    end
    return out
end

function Config:getServer(idx)
    self:load()
    local s = self.servers[idx]
    return s and shallowCopy(s) or nil
end

function Config:getServerCount()
    self:load()
    return #self.servers
end

function Config:addServer(server)
    self:load()
    table.insert(self.servers, normalizeServer(server))
    self.updated = true
    return #self.servers
end

function Config:updateServer(idx, server)
    self:load()
    if not self.servers[idx] then return false end
    self.servers[idx] = normalizeServer(server)
    self.updated = true
    return true
end

function Config:removeServer(idx)
    self:load()
    if not self.servers[idx] then return false end
    table.remove(self.servers, idx)
    -- 默认服务器索引需要跟着修正
    local def = self:getDefaultServerIndex()
    if def then
        if def == idx then
            self:setDefaultServerIndex(nil)
        elseif def > idx then
            self:setDefaultServerIndex(def - 1)
        end
    end
    self.updated = true
    return true
end

function Config:getDefaultServerIndex()
    self:load()
    if not self.settings then return nil end
    return self.settings:readSetting("default_server")
end

function Config:setDefaultServerIndex(idx)
    self:load()
    if not self.settings then return end
    self.settings:saveSetting("default_server", idx)
    self.updated = true
end

function Config:getMaxCacheMB()
    self:load()
    if not self.settings then return self.DEFAULT_MAX_CACHE_MB end
    return self.settings:readSetting("max_cache_mb", self.DEFAULT_MAX_CACHE_MB)
end

function Config:setMaxCacheMB(n)
    self:load()
    if not self.settings then return end
    self.settings:saveSetting("max_cache_mb", n)
    self.updated = true
end

--- 是否在打开远程文件后，关闭阅读器时自动回到远程浏览界面。
function Config:getReturnToBrowser()
    self:load()
    if not self.settings then return true end
    return self.settings:readSetting("return_to_browser", true)
end

function Config:setReturnToBrowser(v)
    self:load()
    if not self.settings then return end
    self.settings:saveSetting("return_to_browser", v and true or false)
    self.updated = true
end

--- 删除缓存后是否保留文件（离线可读）。默认关闭。
function Config:getKeepCache()
    self:load()
    if not self.settings then return false end
    return self.settings:readSetting("keep_cache", false)
end

function Config:setKeepCache(v)
    self:load()
    if not self.settings then return end
    self.settings:saveSetting("keep_cache", v and true or false)
    self.updated = true
end

--- 确保目录存在（递归创建）。
-- @param dir string 绝对路径
-- @return boolean ok
function Config.ensureDir(dir)
    if not dir or dir == "" then return false end
    local mode = lfs.attributes(dir, "mode")
    if mode == "directory" then return true end
    if mode then return false end -- 存在但不是目录
    -- 逐级向上创建
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= dir then
        Config.ensureDir(parent)
    end
    local ok, _, code = lfs.mkdir(dir)
    if ok then return true end
    -- 并发创建时可能已存在
    if lfs.attributes(dir, "mode") == "directory" then return true end
    logger.warn("webdavreader: 创建目录失败", dir, code)
    return false
end

--- 落盘（只在有改动时写）。
function Config:save()
    self:load()
    if not self.settings then return false end
    if not self.updated then return true end
    self.settings:saveSetting("servers", self.servers)
    self.settings:flush()
    self.updated = false
    return true
end

--- 供 onFlushSettings 事件调用。
function Config:flush()
    return self:save()
end

--- 测试用：注入内存版 settings，避免依赖 KOReader 的 DataStorage。
-- 注入后自动重新读取服务器列表。
function Config:_setSettingsForTest(settings)
    self.settings = settings
    self.servers = nil
    if settings then
        self:load()
    end
end

-- 校验地址是否可接受
-- @return ok, err
function Config.validateAddress(address)
    if not address or address == "" then
        return false, "address is empty"
    end
    if not address:match("^https?://[^/]+") then
        return false, "address must start with http:// or https://"
    end
    return true, nil
end

--- 规范化用户输入的服务器地址：去掉末尾斜杠。
function Config.normalizeAddress(address)
    if not address then return "" end
    address = util.trim(address)
    address = address:gsub("/+$", "")
    return address
end

return Config
