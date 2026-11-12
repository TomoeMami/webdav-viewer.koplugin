-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
WebDAV 远程读取插件 —— 远程文件管理操作层（删除 / 移动 / 新建目录）

本模块位于 browser.lua（UI）与 webdav.lua（网络层）之间，职责是：
  * 把客户端的原始返回值翻译成「操作名 + 英文短句」的错误消息；
  * 维护进度记录（wdr/progress）与临时缓存（wdr/cache）的联动；
  * 提供纯函数式的名字校验、目标校验，供 UI 在弹窗前预检。

设计约束（见 INTERFACE.md）：
  * 不 require socket / uimanager，绝不弹 UI，错误只通过返回值传递；
  * 客户端一律经 self.get_client(server) 获取，便于注入假 client 做单测；
  * Lua 5.1 语法（无 goto、无位运算）。

返回约定：
    deleteFile   -> ok, err
    deleteFolder -> ok, count, err
    moveItem     -> ok, err
    renameFile   -> ok, new_path, err
    createFolder -> ok, new_path, err
    countFolderItems -> file_count, folder_count, err
    validateName / validateMoveTarget -> ok, err

@module koplugin.webdavreader.manager
--]]--

local Store = require("wdr.store")

-- gettext 在桌面 Lua 单测环境下不存在，退化为恒等函数。
local _ = function(s) return s end
local ok_gettext, gettext = pcall(require, "gettext")
if ok_gettext and type(gettext) == "function" then
    _ = gettext
end

local Manager = {}
Manager.__index = Manager

-- 递归删除的安全阀：超过任一上限就中止并报错，绝不无限下钻。
Manager.default_max_depth = 8
Manager.default_max_items = 2000

-- 单例形态的默认值（虽以 Manager:new{} 构造为主，但模块本身也可直接注入依赖后使用）。
Manager.max_depth = Manager.default_max_depth
Manager.max_items = Manager.default_max_items

-- 名字中不允许出现的字符：路径分隔符、Windows 保留字符、控制字符。
local INVALID_NAME_CHARS = '[%z\1-\31/\\:*?"<>|]'
local MAX_NAME_LEN = 255

--- 创建管理器实例。
-- @param opts table {
--   config     = Config,             -- 可选，当前未被本模块直接使用，保留给将来
--   progress   = Progress,           -- 进度桥接单例（可为假对象）
--   cache      = Cache,              -- 缓存单例（可为假对象）
--   get_client = function(server),   -- 必需，返回 webdav client
--   max_depth  = number,             -- 可选，递归删除最大目录层数
--   max_items  = number,             -- 可选，递归删除最大条目数
-- }
-- @return Manager
function Manager:new(opts)
    opts = opts or {}
    local self = setmetatable({}, Manager)
    self.config = opts.config
    self.progress = opts.progress
    self.cache = opts.cache
    self.get_client = opts.get_client
    self.max_depth = tonumber(opts.max_depth) or Manager.default_max_depth
    self.max_items = tonumber(opts.max_items) or Manager.default_max_items
    return self
end

--- 把依赖写进模块自身，使其可直接当单例使用（INTERFACE.md 全局规约 1）。
-- @param opts table 同 Manager:new
-- @return Manager 自身
function Manager:setup(opts)
    opts = opts or {}
    self.config = opts.config or self.config
    self.progress = opts.progress or self.progress
    self.cache = opts.cache or self.cache
    self.get_client = opts.get_client or self.get_client
    self.max_depth = tonumber(opts.max_depth) or self.max_depth or Manager.default_max_depth
    self.max_items = tonumber(opts.max_items) or self.max_items or Manager.default_max_items
    return self
end

-- ---------------------------------------------------------------------------
-- 内部工具
-- ---------------------------------------------------------------------------

--- 取客户端；失败时返回 nil, 错误短句。绝不抛异常。
function Manager:_client(server)
    if type(self.get_client) ~= "function" then
        return nil, _("No WebDAV client available")
    end
    local ok, client = pcall(self.get_client, server)
    if not ok then
        return nil, string.format(_("Cannot reach server: %s"), tostring(client))
    end
    if type(client) ~= "table" then
        return nil, _("No WebDAV client available")
    end
    return client
end

--- 安全地调用客户端方法：既容忍方法缺失，也容忍方法内部抛异常。
-- @param client table webdav client
-- @param method string 方法名（list / delete / move / mkdir / exists）
-- @param ... 传给方法的参数
-- @return boolean pcall_ok, any 原返回值1, any 原返回值2
function Manager:_call(client, method, ...)
    local fn = client and client[method]
    if type(fn) ~= "function" then
        return false, string.format(_("Client does not support %s"), method)
    end
    local ok, a, b = pcall(fn, client, ...)
    if not ok then
        return false, tostring(a)
    end
    return true, a, b
end

--- 删除失败时保留底层英文错误，并加上操作名前缀。
local function prefixError(prefix, err)
    local msg = err
    if msg == nil or msg == "" then
        msg = _("unknown error")
    else
        msg = tostring(msg)
    end
    return prefix .. ": " .. msg
end

--- 通知进度层删除记录（假对象可能没有该方法）。
function Manager:_removeProgress(server, remote_path)
    local P = self.progress
    if P and type(P.remove) == "function" then
        pcall(P.remove, P, server, remote_path)
    end
end

--- 通知缓存层失效（假对象可能没有该方法）。
function Manager:_invalidate(server, remote_path)
    local C = self.cache
    if C and type(C.invalidate) == "function" then
        pcall(C.invalidate, C, server, remote_path)
    end
end

--- 通知进度层把旧路径的进度迁到新路径。只有 webdav 明确成功后才调用。
-- 参数按 wdr/progress.lua 的实际签名：Progress:rename(server, old_path, new_path)。
-- （INTERFACE.md 里写成 old_server_old_path / new_server_new_path，是「旧键、新键」的
-- 说明性写法；实现层按单服务器 + 两个路径调用。）
function Manager:_renameProgress(server, old_path, new_path)
    local P = self.progress
    if P and type(P.rename) == "function" then
        pcall(P.rename, P, server, old_path, new_path)
    end
end

--- 递归扫描目录，收集后序遍历的删除顺序与统计信息。
-- 后序保证：先删文件、再删子目录、最后删父目录。
-- @param client table webdav client
-- @param dir string 归一化后的目录路径
-- @param depth number 当前目录层数（根为 1）
-- @param state table { order = {}, count = 0, file_count = 0, folder_count = 0 }
-- @param collect boolean 是否记录删除顺序
-- @return boolean ok, string|nil err
function Manager:_scan(client, dir, depth, state, collect)
    if depth > self.max_depth then
        return nil, string.format(_("Folder nesting exceeds %d levels"), self.max_depth)
    end
    local cok, items, err = self:_call(client, "list", dir)
    if not cok then
        return nil, prefixError(_("List failed"), items)
    end
    if not items then
        return nil, prefixError(_("List failed"), err)
    end
    if type(items) ~= "table" then
        return nil, _("List failed: invalid server response")
    end
    for i = 1, #items do
        local item = items[i]
        -- 容忍服务器把 "." / ".." 也列出来
        local name = item and item.name
        if name and name ~= "" and name ~= "." and name ~= ".." then
            local child_path = item.path
            if not child_path or child_path == "" then
                child_path = Store.joinRemotePath(dir, name)
            end
            state.count = state.count + 1
            if state.count > self.max_items then
                return nil, string.format(_("Folder contains more than %d items"), self.max_items)
            end
            if item.is_folder then
                state.folder_count = state.folder_count + 1
                local sok, serr = self:_scan(client, child_path, depth + 1, state, collect)
                if not sok then return nil, serr end
                if collect then
                    table.insert(state.order, { path = child_path, is_folder = true })
                end
            else
                state.file_count = state.file_count + 1
                if collect then
                    table.insert(state.order, { path = child_path, is_folder = false })
                end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 校验（纯函数 / 只读客户端）
-- ---------------------------------------------------------------------------

--- 校验一个文件名或目录名是否可作为远程名字。
-- 拒绝：空、仅空白、"."、".."、含 / \ : * ? " < > | 或控制字符、
--       以 "." 或空格结尾、超长（> 255）。
-- @param name string|nil
-- @return boolean ok, string|nil err
function Manager:validateName(name)
    if name == nil or type(name) ~= "string" then
        return false, _("Name must not be empty")
    end
    if name == "" or name:match("^%s*$") then
        return false, _("Name must not be empty")
    end
    if name == "." or name == ".." then
        return false, _("Name must not be . or ..")
    end
    if #name > MAX_NAME_LEN then
        return false, string.format(_("Name is longer than %d characters"), MAX_NAME_LEN)
    end
    local bad = name:match(INVALID_NAME_CHARS)
    if bad then
        return false, string.format(_("Name contains an invalid character: %s"), bad)
    end
    if name:sub(-1) == "." then
        return false, _("Name must not end with a dot")
    end
    if name:sub(-1) == " " then
        return false, _("Name must not end with a space")
    end
    return true
end

--- 校验移动/重命名的目标是否合理。
-- 检查：源或目标为空、源目标相同、目标位于源自身内部、目标名非法、目标已存在。
-- @param server table
-- @param from_path string 源相对路径
-- @param to_path string 目标相对路径
-- @return boolean ok, string|nil err
function Manager:validateMoveTarget(server, from_path, to_path)
    local from = Store.normalizeDir(from_path)
    local to = Store.normalizeDir(to_path)
    if from == "" then
        return false, _("Invalid source path")
    end
    if to == "" then
        return false, _("Invalid target path")
    end
    if from == to then
        return false, _("Source and target are the same")
    end
    -- 目标在源目录之下（例如把 a 移到 a/b/a）会形成自包含
    if to:sub(1, #from + 1) == from .. "/" then
        return false, _("Cannot move a folder into itself")
    end
    local target_name = Store.getRemoteFileName(to)
    local nok, nerr = self:validateName(target_name)
    if not nok then return false, nerr end

    local client, cerr = self:_client(server)
    if not client then return false, cerr end
    if type(client.exists) == "function" then
        local eok, exists = self:_call(client, "exists", to)
        if eok and exists then
            return false, string.format(_("Target already exists: %s"), target_name)
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 统计与删除
-- ---------------------------------------------------------------------------

--- 统计目录下的文件数与目录数，用于删除前提示。
-- @param server table
-- @param remote_path string 目录相对路径
-- @return number|nil file_count, number|nil folder_count, string|nil err
function Manager:countFolderItems(server, remote_path)
    local client, cerr = self:_client(server)
    if not client then return nil, nil, cerr end
    local root = Store.normalizeDir(remote_path)
    local state = { order = {}, count = 0, file_count = 0, folder_count = 0 }
    local ok, err = self:_scan(client, root, 1, state, false)
    if not ok then return nil, nil, err end
    return state.file_count, state.folder_count, nil
end

--- 删除单个文件；成功后清理进度记录与缓存。
-- @param server table
-- @param remote_path string
-- @return boolean ok, string|nil err
function Manager:deleteFile(server, remote_path)
    local client, cerr = self:_client(server)
    if not client then return false, cerr end
    local path = Store.normalizeDir(remote_path)
    if path == "" then
        return false, _("Invalid file path")
    end
    local cok, ok, err = self:_call(client, "delete", path)
    if not cok then
        return false, prefixError(_("Delete failed"), ok)
    end
    if not ok then
        return false, prefixError(_("Delete failed"), err)
    end
    self:_removeProgress(server, path)
    self:_invalidate(server, path)
    return true
end

--- 递归删除目录：先统计再自底向上删除。
-- 安全阀：max_depth 层数上限 + max_items 条目上限，任一超限即中止（此时尚未删除任何东西）。
-- @param server table
-- @param remote_path string
-- @return boolean ok, number|nil count（被删除的子项数，不含目录自身）, string|nil err
function Manager:deleteFolder(server, remote_path)
    local client, cerr = self:_client(server)
    if not client then return false, nil, cerr end
    local root = Store.normalizeDir(remote_path)
    if root == "" then
        return false, nil, _("Cannot delete the server root folder")
    end
    -- 第一遍：统计 + 收集后序删除顺序（同时完成「先统计数量」的要求）
    local state = { order = {}, count = 0, file_count = 0, folder_count = 0 }
    local ok, err = self:_scan(client, root, 1, state, true)
    if not ok then return false, nil, err end
    -- 第二遍：按后序逐个删除
    for i = 1, #state.order do
        local entry = state.order[i]
        local cok, dok, derr = self:_call(client, "delete", entry.path)
        if not cok then
            return false, nil, prefixError(
                string.format(_("Delete failed for %s"), entry.path), dok)
        end
        if not dok then
            return false, nil, prefixError(
                string.format(_("Delete failed for %s"), entry.path), derr)
        end
        self:_removeProgress(server, entry.path)
        self:_invalidate(server, entry.path)
    end
    local cok2, rok, rerr = self:_call(client, "delete", root)
    if not cok2 then
        return false, nil, prefixError(_("Delete failed"), rok)
    end
    if not rok then
        return false, nil, prefixError(_("Delete failed"), rerr)
    end
    self:_removeProgress(server, root)
    self:_invalidate(server, root)
    return true, state.count, nil
end

-- ---------------------------------------------------------------------------
-- 移动 / 重命名 / 新建
-- ---------------------------------------------------------------------------

--- 移动或重命名远程条目；只有 webdav 确认成功后才迁移进度与失效缓存。
-- @param server table
-- @param from_path string
-- @param to_path string
-- @return boolean ok, string|nil err
function Manager:moveItem(server, from_path, to_path)
    local client, cerr = self:_client(server)
    if not client then return false, cerr end
    local from = Store.normalizeDir(from_path)
    local to = Store.normalizeDir(to_path)
    if from == "" or to == "" then
        return false, _("Invalid move path")
    end
    if from == to then
        return false, _("Source and target are the same")
    end
    -- 发出请求前校验目标：拦住「把目录移到它自己下面」这类自包含路径，
    -- 以及非法文件名、目标已存在（服务器侧 MOVE 带 Overwrite:F，提前拒绝体验更好）。
    local vok, verr = self:validateMoveTarget(server, from, to)
    if not vok then
        return false, verr
    end
    local cok, ok, err = self:_call(client, "move", from, to)
    if not cok then
        return false, prefixError(_("Move failed"), ok)
    end
    if not ok then
        return false, prefixError(_("Move failed"), err)
    end
    -- 成功之后才动进度/缓存，失败时保持原状
    self:_renameProgress(server, from, to)
    self:_invalidate(server, from)
    return true
end

--- 同目录内改名。
-- @param server table
-- @param remote_path string 原路径
-- @param new_name string 新文件名（不含目录）
-- @return boolean ok, string|nil new_path, string|nil err
function Manager:renameFile(server, remote_path, new_name)
    local path = Store.normalizeDir(remote_path)
    if path == "" then
        return false, nil, _("Invalid file path")
    end
    local nok, nerr = self:validateName(new_name)
    if not nok then return false, nil, nerr end
    local dir = Store.getRemoteDir(path)
    local new_path = Store.joinRemotePath(dir, new_name)
    if new_path == path then
        return false, nil, _("New name is the same as the old name")
    end
    local vok, verr = self:validateMoveTarget(server, path, new_path)
    if not vok then return false, nil, verr end
    local mok, merr = self:moveItem(server, path, new_path)
    if not mok then return false, nil, merr end
    return true, new_path, nil
end

--- 在指定父目录下新建目录。
-- @param server table
-- @param parent_path string 父目录相对路径（"" 表示服务器根）
-- @param name string 新目录名
-- @return boolean ok, string|nil new_path, string|nil err
function Manager:createFolder(server, parent_path, name)
    local nok, nerr = self:validateName(name)
    if not nok then return false, nil, nerr end
    local client, cerr = self:_client(server)
    if not client then return false, nil, cerr end
    local new_path = Store.joinRemotePath(Store.normalizeDir(parent_path), name)
    if new_path == "" then
        return false, nil, _("Invalid folder name")
    end
    local cok, ok, err = self:_call(client, "mkdir", new_path)
    if not cok then
        return false, nil, prefixError(_("Create folder failed"), ok)
    end
    if not ok then
        return false, nil, prefixError(_("Create folder failed"), err)
    end
    return true, new_path, nil
end

return Manager
