-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
跨插件实例的会话状态

为什么需要这个模块：
  KOReader 在 FileManager 和 Reader 里各自创建一份插件实例（PluginLoader 每次 new），
  于是「在浏览界面点开哪个远程文件」这个信息如果只存在 FileManager 那份实例上，
  Reader 那份实例就读不到，进度也就没法按远程键回写。
  本模块用模块级单例（package.loaded 缓存）承载这类跨实例状态。

存放内容：
  current     本次会话正在阅读的远程文件 { server, remote_path, local_path, key }
  local_map   本地缓存路径 -> 远程信息（持久化在 state 文件里，跨重启有效）
  reading     是否处于「我们发起的阅读」中，用于决定关书后是否返回列表

@module koplugin.webdavreader.session
--]]--

local Session = {
    current = nil,
    -- 本地路径 -> { server_address, server_name, remote_path }
    local_map = {},
    -- 本次会话是否从本插件发起的阅读
    reading = false,
    -- 最近浏览位置（按服务器地址分别记忆，避免 A 服务器的目录被用到 B 服务器上）
    last_server_idx = nil,
    last_paths = {},
}

--- 登记「即将阅读的远程文件」。
-- @param server table
-- @param remote_path string
-- @param local_path string
-- @param key string 进度键
function Session.setCurrent(server, remote_path, local_path, key)
    Session.current = {
        server = server,
        remote_path = remote_path,
        local_path = local_path,
        key = key,
    }
    Session.reading = true
    if local_path then
        Session.local_map[local_path] = {
            server_address = server and server.address or "",
            server_name = server and server.name or "",
            remote_path = remote_path,
        }
    end
    return Session.current
end

--- 清空当前阅读上下文（关书后调用）。
function Session.clearCurrent()
    Session.current = nil
    Session.reading = false
end

--- 按本地路径查远程信息。
-- @param local_path string
-- @return table|nil { server_address, server_name, remote_path }
function Session.getRemoteByLocalPath(local_path)
    if not local_path then return nil end
    return Session.local_map[local_path]
end

--- 从持久化数据恢复 local_map。
-- @param data table { [local_path] = "address\tname\tremote_path" } 或已是 table
function Session.loadMap(data)
    Session.local_map = {}
    if type(data) ~= "table" then return end
    for local_path, encoded in pairs(data) do
        if type(encoded) == "string" then
            local address, name, remote_path = encoded:match("^([^\t]*)\t([^\t]*)\t(.+)$")
            if remote_path then
                Session.local_map[local_path] = {
                    server_address = address,
                    server_name = name,
                    remote_path = remote_path,
                }
            end
        elseif type(encoded) == "table" then
            Session.local_map[local_path] = encoded
        end
    end
end

--- 导出为可持久化的扁平表。
-- @return table { [local_path] = "address\tname\tremote_path" }
function Session.exportMap()
    local out = {}
    for local_path, info in pairs(Session.local_map) do
        out[local_path] = table.concat({
            info.server_address or "",
            info.server_name or "",
            info.remote_path or "",
        }, "\t")
    end
    return out
end

--- 记录某服务器上最后浏览的远程目录。
-- @param server_address string 服务器地址（作为隔离键）
-- @param path string 远程相对目录
function Session.setLastPath(server_address, path)
    if not server_address then return end
    Session.last_paths[server_address] = path
end

--- 取某服务器上最后浏览的远程目录。
function Session.getLastPath(server_address)
    if not server_address then return nil end
    return Session.last_paths[server_address]
end

--- 测试用：重置全部状态。
function Session.reset()
    Session.current = nil
    Session.local_map = {}
    Session.reading = false
    Session.last_server_idx = nil
    Session.last_paths = {}
end

return Session
