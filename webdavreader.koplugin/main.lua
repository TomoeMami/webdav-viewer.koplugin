-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
WebDAV 远程阅读插件 —— 插件入口

功能概览：
  1. 在一个界面里浏览 WebDAV 服务器上的文件与目录；
  2. 点开文件即用 KOReader 阅读，**不需要指定本地下载目录**
     （内部下载到插件自己的临时缓存目录）；
  3. 阅读进度保存在本插件独有的 JSON（webdavreader_progress.json），
     以「服务器 + 远程路径 + 文件名」为键，缓存清空也不丢；
  4. 界面内提供删除 / 移动 / 重命名 / 新建目录等远程文件管理操作。

与官方 cloudstorage.koplugin 的差异（这是本插件存在的理由）：
  * cloudstorage 必须「选择下载目录 -> 保存 -> 再打开」，本插件直接打开；
  * cloudstorage 的进度依赖 KOReader sidecar（跟着本地路径走），
    本插件用远程路径做键，换设备/清缓存都能恢复；
  * cloudstorage 的删除是单文件，本插件支持目录递归删除与移动。

@module koplugin.webdavreader
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Cache = require("wdr.cache")
local Config = require("wdr.config")
local History = require("wdr.history")
local Manager = require("wdr.manager")
local Progress = require("wdr.progress")
local Session = require("wdr.session")
local Sort = require("wdr.sort")
local Store = require("wdr.store")
local WebDAV = require("wdr.webdav")

local WebDavReader = WidgetContainer:extend{
    name = "webdavreader",
    is_doc_only = false,
    settings = nil,
    -- 进度快照节流参数：滚动模式每 60 秒最多一次；翻页模式每 10 页触发一次（再经 60 秒节流）
    PROGRESS_SNAPSHOT_INTERVAL = 60,
    PROGRESS_SNAPSHOT_EVERY = 10,
}

--------------------------------------------------------------------------------
-- 初始化
--------------------------------------------------------------------------------

function WebDavReader:init()
    self.clients = {}
    self.updated = nil

    Config:load()
    Progress:init()
    History:init()
    Cache:setDir(Config:getCacheDir())
    Manager:setup{
        config = Config,
        progress = Progress,
        cache = Cache,
        get_client = function(server) return self:getClientFor(server) end,
    }

    self:loadState()

    -- FileManager 有主菜单；Reader 也需要注册（用于阅读时的菜单入口）
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
end

function WebDavReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("webdavreader", {
        category = "none",
        event = "ShowWebDavReaderBrowser",
        title = _("WebDAV 远程阅读"),
        general = true,
    })
end

--------------------------------------------------------------------------------
-- 主菜单
--------------------------------------------------------------------------------

function WebDavReader:addToMainMenu(menu_items)
    menu_items.webdavreader = {
        text = _("WebDAV 远程阅读"),
        -- 挂到「工具」下（与官方 cloudstorage 一致；FileManager 与 Reader 两套菜单都有 tools）
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("浏览远程文件"),
                callback = function()
                    self:showBrowser()
                end,
            },
            {
                text = _("服务器设置"),
                callback = function()
                    self:showServerList()
                end,
            },
            {
                text = _("缓存设置"),
                callback = function()
                    self:showCacheDialog()
                end,
            },
            {
                text = _("阅读进度记录"),
                callback = function()
                    self:showProgressList()
                end,
            },
            {
                text = _("移动位置记录"),
                callback = function()
                    self:showMoveHistory()
                end,
            },
        },
    }
end

--- dispatcher / 事件入口。server_idx 由 _reopenBrowserAfterReaderClosed 广播时传入。
function WebDavReader:onShowWebDavReaderBrowser(server_idx)
    self:showBrowser(server_idx)
    return true
end

--------------------------------------------------------------------------------
-- 服务器配置
--------------------------------------------------------------------------------

--- 获取（并缓存）某个服务器的 WebDAV 客户端。
function WebDavReader:getClientFor(server)
    if not server or not server.address then return nil, "服务器未配置" end
    local key = tostring(server.address) .. "|" .. tostring(server.username or "")
    if self.clients[key] then
        return self.clients[key]
    end

    if not NetworkMgr:isOnline() then
        return nil, _("当前没有网络连接，请先连接 Wi-Fi。")
    end

    local client, err = WebDAV.client(server)
    if not client then
        return nil, err
    end
    self.clients[key] = client
    return client
end

function WebDavReader:showBrowser(server_idx)
    local servers = Config:getServers()
    if #servers == 0 then
        UIManager:show(InfoMessage:new{
            text = _("还没有配置 WebDAV 服务器。"),
            timeout = 2,
        })
        self:showServerSettings(nil)
        return
    end

    local idx = server_idx or Session.last_server_idx or Config:getDefaultServerIndex()
    if not idx or not Config:getServer(idx) then
        if #servers == 1 then
            idx = 1
        else
            self:showServerList(true)
            return
        end
    end

    self:openBrowserFor(idx)
end

function WebDavReader:openBrowserFor(server_idx)
    local Browser = require("wdr.browser")
    local server = Config:getServer(server_idx)
    if not server then return end

    -- 恢复上次的排序偏好（非法/缺失值由 Sort.resolve 兜底成默认值）
    local saved_key = self:readSetting("sort_key")
    local saved_descending = self:readSetting("sort_descending")
    local saved_folders_first = self:readSetting("sort_folders_first")

    -- 注意：Widget 的 new() 会自动调用 init()，这里不要再手动调一次，
    -- 否则会把 paths 栈和 server_idx 重置掉。
    local browser = Browser:new{
        plugin = self,
        config = Config,
        progress = Progress,
        cache = Cache,
        manager = Manager,
        server_idx = server_idx,
        -- 左侧按钮必须在这里声明：Menu:init 用 title_bar_left_icon 判断是否创建左按钮，
        -- 而 Browser:init 里不能调 setTitleBarLeftIcon（那时 title_bar 还没建）。
        -- 少了这一项，左上角按钮根本不会出现，目录菜单（含排序设置）就无从打开。
        title_bar_left_icon = "appbar.menu",
        sort_key = Sort.resolve(saved_key),
        sort_descending = saved_descending == true,
        sort_folders_first = saved_folders_first ~= false,
        -- 排序变化时回写插件状态，下次进浏览界面沿用
        on_sort_changed = function(key, descending, folders_first)
            self:saveSortSettings(key, descending, folders_first)
        end,
    }
    self.browser = browser
    Session.last_server_idx = server_idx

    local target = Store.normalizeDir(Session.getLastPath(server.address) or "")
    local start = Store.normalizeDir(server.start_dir or "")
    if target == "" then target = start end

    -- 用 openPathAt 而不是 enterPath：恢复出来的可能是深层目录，
    -- 必须让 browser 的 dir_stack 与这个路径自洽，否则「返回上一级」三条退路
    -- （置顶 ⬆ ../、左下角箭头、目录菜单「上一级」）全部失效。
    browser:openPathAt(target, true)
end

--- 把排序偏好写进插件状态（状态量极小，立即落盘）。
function WebDavReader:saveSortSettings(key, descending, folders_first)
    local data = self:readState() or {}
    data.sort_key = Sort.resolve(key)
    data.sort_descending = descending and true or false
    data.sort_folders_first = folders_first ~= false
    self:writeState(data)
end

function WebDavReader:showServerList(for_browse)
    local ButtonDialog = require("ui/widget/buttondialog")
    local servers = Config:getServers()
    local buttons = {}

    for idx, server in ipairs(servers) do
        local is_default = Config:getDefaultServerIndex() == idx
        table.insert(buttons, {
            {
                text = (is_default and "★ " or "") ..
                    (server.name ~= "" and server.name or server.address),
                callback = function()
                    UIManager:close(self.server_list_dialog)
                    if for_browse then
                        Session.last_server_idx = idx
                        self:openBrowserFor(idx)
                    else
                        self:showServerMenu(idx)
                    end
                end,
            },
        })
    end

    if #buttons > 0 then
        table.insert(buttons, {})
    end
    table.insert(buttons, {
        {
            text = _("添加服务器"),
            callback = function()
                UIManager:close(self.server_list_dialog)
                self:showServerSettings(nil)
            end,
        },
    })

    self.server_list_dialog = ButtonDialog:new{
        title = for_browse and _("选择服务器") or _("服务器设置"),
        title_align = "center",
        buttons = buttons,
        dismissable = true,
    }
    UIManager:show(self.server_list_dialog)
end

function WebDavReader:showServerMenu(idx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local server = Config:getServer(idx)
    if not server then return end

    self.server_menu_dialog = ButtonDialog:new{
        title = server.name ~= "" and server.name or server.address,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("编辑"),
                    callback = function()
                        UIManager:close(self.server_menu_dialog)
                        self:showServerSettings(idx)
                    end,
                },
                {
                    text = _("浏览"),
                    callback = function()
                        UIManager:close(self.server_menu_dialog)
                        self:openBrowserFor(idx)
                    end,
                },
            },
            {
                {
                    text = _("设为默认"),
                    callback = function()
                        UIManager:close(self.server_menu_dialog)
                        Config:setDefaultServerIndex(idx)
                        Config:save()
                        UIManager:show(Notification:new{
                            text = T(_("已将 %1 设为默认服务器"), server.name),
                            timeout = 2,
                        })
                    end,
                },
                {
                    text = _("清空进度"),
                    callback = function()
                        UIManager:close(self.server_menu_dialog)
                        UIManager:show(ConfirmBox:new{
                            text = T(_("删除 %1 的全部阅读进度记录？"), server.name) .. "\n\n" ..
                                   _("不会删除远程文件，也不会删除本地缓存。"),
                            ok_text = _("删除"),
                            ok_callback = function()
                                local n = Progress:removeServer(server)
                                UIManager:show(Notification:new{
                                    text = T(_("已删除 %1 条进度记录"), n),
                                    timeout = 2,
                                })
                            end,
                        })
                    end,
                },
            },
            {},
            {
                {
                    text = _("删除服务器"),
                    callback = function()
                        UIManager:close(self.server_menu_dialog)
                        UIManager:show(ConfirmBox:new{
                            text = T(_("删除服务器配置 %1？"), server.name) .. "\n\n" ..
                                   _("同时会删除该服务器的阅读进度记录（远程文件不受影响）。"),
                            ok_text = _("删除"),
                            ok_callback = function()
                                Progress:removeServer(server)
                                Config:removeServer(idx)
                                Config:save()
                                self.clients = {}
                                UIManager:show(Notification:new{
                                    text = _("已删除服务器配置"),
                                    timeout = 2,
                                })
                            end,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(self.server_menu_dialog)
end

function WebDavReader:showServerSettings(idx)
    local server = idx and Config:getServer(idx) or Config.newServer()
    local dialog
    dialog = MultiInputDialog:new{
        title = idx and _("编辑服务器") or _("添加服务器"),
        fields = {
            {
                text = server.name,
                hint = _("名称（例如 我的 NAS）"),
            },
            {
                text = server.address,
                hint = _("地址（例如 https://nas.local:5006/dav）"),
            },
            {
                text = server.username,
                hint = _("用户名"),
            },
            {
                text = server.password,
                text_type = "password",
                hint = _("密码"),
            },
            {
                text = server.start_dir,
                hint = _("起始目录（例如 /books，留空为根目录）"),
            },
        },
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("测试连接"),
                    callback = function()
                        local fields = dialog:getFields()
                        self:testConnection(fields[2], fields[3], fields[4])
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        self:saveServerFromFields(idx, fields)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function WebDavReader:testConnection(address, username, password)
    address = Config.normalizeAddress(address)
    local ok, err = Config.validateAddress(address)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("地址无效：%1"), err), timeout = 3 })
        return
    end
    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{ text = _("当前没有网络连接。"), timeout = 3 })
        return
    end
    local client, client_err = WebDAV.client({
        address = address,
        username = username,
        password = password,
    })
    if not client then
        UIManager:show(InfoMessage:new{ text = T(_("创建客户端失败：%1"), client_err or ""), timeout = 4 })
        return
    end
    -- 提示不自动消失：请求是同步的，服务器慢时会卡住界面，
    -- 若提示 1 秒就消失，用户面对的就是「冻结且无反馈」。
    local busy = InfoMessage:new{ text = _("正在测试连接…") }
    UIManager:show(busy)
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end
    UIManager:nextTick(function()
        local items, list_err = client:list("")
        UIManager:close(busy)
        if items then
            UIManager:show(InfoMessage:new{
                text = T(_("连接成功，根目录有 %1 个项目。"), #items),
                timeout = 3,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("连接失败：\n%1"), list_err or _("未知错误")),
                timeout = 5,
            })
        end
    end)
end

function WebDavReader:saveServerFromFields(idx, fields)
    local address = Config.normalizeAddress(fields[2] or "")
    local ok, err = Config.validateAddress(address)
    if not ok then
        UIManager:show(InfoMessage:new{ text = T(_("地址无效：%1"), err), timeout = 3 })
        return
    end
    local server = {
        name = util.trim(fields[1] or ""),
        address = address,
        username = fields[3] or "",
        password = fields[4] or "",
        start_dir = fields[5] or "/",
    }
    if server.name == "" then
        server.name = address
    end

    if idx then
        Config:updateServer(idx, server)
    else
        idx = Config:addServer(server)
        if not Config:getDefaultServerIndex() then
            Config:setDefaultServerIndex(idx)
        end
    end
    Config:save()
    self.clients = {}

    UIManager:show(Notification:new{
        text = _("已保存"),
        timeout = 2,
    })
end

--------------------------------------------------------------------------------
-- 缓存设置
--------------------------------------------------------------------------------

function WebDavReader:showCacheDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local size_mb = Cache:sizeBytes() / 1024 / 1024
    local max_mb = Config:getMaxCacheMB()

    self.cache_dialog = ButtonDialog:new{
        title = T(_("缓存\n\n已用：%1 MB\n上限：%2 MB"), string.format("%.1f", size_mb), max_mb),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("设置上限"),
                    callback = function()
                        UIManager:close(self.cache_dialog)
                        self:showCacheLimitDialog()
                    end,
                },
                {
                    text = _("立即清理"),
                    callback = function()
                        UIManager:close(self.cache_dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("清空本地缓存？") .. "\n\n" ..
                                   _("远程文件与阅读进度都不会受影响，下次打开会重新下载。"),
                            ok_text = _("清理"),
                            ok_callback = function()
                                local ok, freed = Cache:clear()
                                UIManager:show(Notification:new{
                                    text = ok and T(_("已释放 %1 MB"), string.format("%.1f", freed / 1024 / 1024))
                                        or _("清理失败"),
                                    timeout = 2,
                                })
                            end,
                        })
                    end,
                },
            },
            {},
            {
                {
                    text = Config:getKeepCache() and _("阅读后保留缓存：开") or _("阅读后保留缓存：关"),
                    callback = function()
                        UIManager:close(self.cache_dialog)
                        Config:setKeepCache(not Config:getKeepCache())
                        Config:save()
                        UIManager:show(Notification:new{
                            text = Config:getKeepCache() and _("将保留缓存") or _("关闭后清理缓存"),
                            timeout = 2,
                        })
                    end,
                },
            },
            {
                {
                    text = Config:getReturnToBrowser() and _("关闭后返回列表：开") or _("关闭后返回列表：关"),
                    callback = function()
                        UIManager:close(self.cache_dialog)
                        Config:setReturnToBrowser(not Config:getReturnToBrowser())
                        Config:save()
                        UIManager:show(Notification:new{
                            text = Config:getReturnToBrowser() and _("将返回列表") or _("不再返回列表"),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(self.cache_dialog)
end

function WebDavReader:showCacheLimitDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("缓存上限（MB）"),
        input = tostring(Config:getMaxCacheMB()),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local n = tonumber(dialog:getInputText())
                        UIManager:close(dialog)
                        if not n or n <= 0 then
                            UIManager:show(InfoMessage:new{ text = _("请输入正数。"), timeout = 2 })
                            return
                        end
                        n = math.floor(n)
                        Config:setMaxCacheMB(n)
                        Config:save()
                        Cache:prune(n)
                        UIManager:show(Notification:new{
                            text = T(_("上限已设为 %1 MB"), n),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--------------------------------------------------------------------------------
-- 进度列表
--------------------------------------------------------------------------------

function WebDavReader:showProgressList()
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local entries = Progress:list()
    if #entries == 0 then
        UIManager:show(InfoMessage:new{ text = _("还没有任何阅读进度记录。"), timeout = 2 })
        return
    end

    local buttons = {}
    local shown = 0
    for entry_idx, e in ipairs(entries) do
        if shown >= 30 then break end
        local label = e.entry.remote_path or e.key
        local pct = Progress.formatEntry(e.entry)
        if pct then
            label = label .. "  " .. pct
        end
        table.insert(buttons, {
            {
                text = label,
                callback = function()
                    UIManager:close(self.progress_dialog)
                    UIManager:show(InfoMessage:new{
                        text = T(_("文件：%1\n服务器：%2\n进度：%3\n更新时间：%4"),
                            e.entry.remote_path or "-",
                            e.entry.server_name or "-",
                            pct or "-",
                            e.entry.updated and os.date("%Y-%m-%d %H:%M", e.entry.updated) or "-"),
                    })
                end,
            },
        })
        shown = shown + 1
    end

    table.insert(buttons, {})
    table.insert(buttons, {
        {
            text = _("清空全部进度"),
            callback = function()
                UIManager:close(self.progress_dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("删除所有阅读进度记录？") .. "\n\n" .. _("远程文件与缓存不受影响。"),
                    ok_text = _("删除"),
                    ok_callback = function()
                        -- 不用 "_" 当占位变量：本文件顶部 local _ = require("gettext")，
                        -- 用 "_" 会在循环内遮蔽它，之后在这个作用域里写 _(...) 都会崩。
                        for srv_idx, s in ipairs(Config:getServers()) do
                            Progress:removeServer(s)
                        end
                        Progress:flush()
                        UIManager:show(Notification:new{ text = _("已清空"), timeout = 2 })
                    end,
                })
            end,
        },
    })

    self.progress_dialog = ButtonDialog:new{
        title = T(_("阅读进度（%1 条）"), #entries),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.progress_dialog)
end

--------------------------------------------------------------------------------
-- 移动位置历史
--------------------------------------------------------------------------------

--- 查看/清理「移动」用过的目标目录。
-- 浏览界面里的「移动」会自动带上最近的历史，这个入口用于集中查看与清理。
function WebDavReader:showMoveHistory()
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")

    -- 按服务器分组列出：不同服务器上的同名目录不能互相混用
    local buttons = {}
    local total = 0
    for server_idx, server in ipairs(Config:getServers()) do
        local entries = History:list(server)
        if #entries > 0 then
            -- 服务器名当分组标题：不可点，所以不挂 callback
            -- （Button 在 enabled=false 时不会触发点击，官方占位按钮也是这么写的）
            table.insert(buttons, {
                {
                    text = server.name ~= "" and server.name or server.address,
                    enabled = false,
                },
            })
            for entry_idx, entry in ipairs(entries) do
                table.insert(buttons, {
                    {
                        text = History.formatLabel(entry),
                        align = "left",
                        callback = function()
                            UIManager:close(self.move_history_dialog)
                            UIManager:show(ConfirmBox:new{
                                text = T(_("从历史中移除 %1？"),
                                    History.formatDir(server, entry.dir)) .. "\n\n" ..
                                        _("只是忘掉这个快捷位置，不会删除服务器上的任何文件。"),
                                ok_text = _("移除"),
                                ok_callback = function()
                                    History:remove(server, entry.dir)
                                    UIManager:show(Notification:new{
                                        text = _("已移除"),
                                        timeout = 2,
                                    })
                                end,
                            })
                        end,
                    },
                })
                total = total + 1
            end
            table.insert(buttons, {})
        end
    end

    if total == 0 then
        UIManager:show(InfoMessage:new{
            text = _("还没有移动记录。") .. "\n\n" ..
                _("在浏览界面长按文件或目录 → 移动，成功移动后这里会记住目标位置。"),
            timeout = 3,
        })
        return
    end

    table.insert(buttons, {
        {
            text = _("清空全部移动记录"),
            callback = function()
                UIManager:close(self.move_history_dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(_("清空 %1 条移动位置记录？"), total) .. "\n\n" ..
                        _("只是忘掉快捷位置，不会删除服务器上的任何文件。"),
                    ok_text = _("清空"),
                    ok_callback = function()
                        History:clear(nil)
                        UIManager:show(Notification:new{ text = _("已清空"), timeout = 2 })
                    end,
                })
            end,
        },
    })

    self.move_history_dialog = ButtonDialog:new{
        title = T(_("移动位置记录（%1 条）"), total),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.move_history_dialog)
end

--------------------------------------------------------------------------------
-- 打开远程文件
--------------------------------------------------------------------------------

--- 由 browser.lua 调用：打开已下载到本地的远程文件。
function WebDavReader:openRemoteFile(server, item, local_path)
    local key = Progress:getKey(server, item.remote_path)
    Session.setCurrent(server, item.remote_path, local_path, key)
    Session.setLastPath(server.address, Store.getRemoteDir(item.remote_path))
    self:saveState()

    -- 关闭浏览界面，避免与 Reader 堆叠
    if self.browser then
        UIManager:close(self.browser)
    end

    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    filemanagerutil.openFile(self.ui, local_path, nil, true)
end

--------------------------------------------------------------------------------
-- 进度：Reader 事件钩子
--
-- KOReader 在 ReaderUI 里会为每个插件创建独立实例，事件按 "on"..Event.name 分发。
-- 因为这些方法写在插件原型上，Reader 里的那份实例也能收到事件。
--------------------------------------------------------------------------------

--- Reader 读取进度之前触发（此时 doc_settings 已有 sidecar 内容，但还没被 Reader 消费）。
--- 由本地文件路径反查它对应的远程文件上下文。
-- 两种情况：一是本次会话刚由插件打开（Session.current 命中），
-- 二是进程重启后从 KOReader 的历史记录直接打开缓存文件（靠持久化的 local_map 反查）。
-- 保存进度与恢复进度都必须走这一个入口，否则两条路径的行为会不一致。
-- @param doc_file string 本地文件绝对路径
-- @return table|nil { server=, remote_path=, local_path=, key= }
function WebDavReader:resolveRemoteFor(doc_file)
    if not doc_file then return nil end

    local current = Session.current
    if current and current.local_path == doc_file then
        return current
    end

    local info = Session.getRemoteByLocalPath(doc_file)
    if not info then return nil end

    -- 按地址找服务器（不用索引：服务器列表可能已经增删过）
    local server
    for srv_idx, srv in ipairs(Config:getServers()) do
        if srv.address == info.server_address then
            server = srv
            break
        end
    end
    if not server then return nil end

    local remote = {
        server = server,
        remote_path = info.remote_path,
        local_path = doc_file,
        key = Progress:getKey(server, info.remote_path),
    }
    -- 命中后补登记，后续本可以直接走 Session.current 快路径
    Session.setCurrent(server, info.remote_path, doc_file, remote.key)
    return remote
end

--- Reader 读取进度之前触发（此时 doc_settings 已有 sidecar 内容，但还没被 Reader 消费）。
function WebDavReader:onDocSettingsLoad(doc_settings, document)
    if not doc_settings then return end
    local doc_file = (document and document.file) or (doc_settings.data and doc_settings.data.doc_path)
    if not doc_file then return end

    local remote = self:resolveRemoteFor(doc_file)
    if not remote then return end

    local entry = Progress:get(remote.server, remote.remote_path)
    if not entry then return end

    -- 合并而不是简单跳过：percent 取较大者，定位信息取与之同源的那份。
    -- 只看时间戳不够可靠——用户可能把缓存文件另存到别处读得更靠后，
    -- 那份 sidecar 里没有 webdavreader_updated，但 percent 更大。
    local sidecar_percent = doc_settings:readSetting("percent_finished")
    local sidecar_updated = doc_settings:readSetting("webdavreader_updated")
    local plugin_percent = entry.percent

    local use_sidecar = false
    if type(sidecar_percent) == "number" and type(plugin_percent) == "number" then
        if sidecar_percent > plugin_percent + 1e-6 then
            use_sidecar = true
        end
    elseif sidecar_updated and entry.updated and entry.updated < sidecar_updated then
        use_sidecar = true
    end

    if use_sidecar then
        -- sidecar 更新：保留它，但把插件记录也更新到这份进度，免得下次又冲突
        logger.dbg("webdavreader: sidecar 进度更靠后，保留 sidecar",
            tostring(sidecar_percent), "vs", tostring(plugin_percent))
        local merged = Progress:extractFromDocSettings(doc_settings)
        if merged then
            Progress:save(remote.server, remote.remote_path, merged)
            Progress:flush()
        end
        return
    end

    Progress:applyToDocSettings(doc_settings, entry)
    doc_settings:saveSetting("webdavreader_updated", entry.updated or 0)
    logger.dbg("webdavreader: 已恢复进度", remote.remote_path, entry.percent or -1)
end

--- 把当前阅读进度写回插件 JSON。
-- @param reason string 仅用于日志
function WebDavReader:saveCurrentProgress(reason)
    local doc_settings = self.ui and self.ui.doc_settings
    if not doc_settings then return end
    local doc_file = self.ui.document and self.ui.document.file
    local remote = self:resolveRemoteFor(doc_file) or Session.current
    if not remote then return end
    if doc_file and remote.local_path and doc_file ~= remote.local_path then return end

    local entry = Progress:extractFromDocSettings(doc_settings)
    if not entry then return end
    entry.updated = os.time()
    Progress:save(remote.server, remote.remote_path, entry)
    Progress:flush()
    doc_settings:saveSetting("webdavreader_updated", entry.updated)
    logger.dbg("webdavreader: 保存进度", reason or "", remote.remote_path,
        entry.percent or -1, entry.xpointer or "", entry.page or -1)
end

function WebDavReader:onSaveSettings()
    if Session.current then
        self:saveCurrentProgress("SaveSettings")
    end
end

--- 阅读过程中的进度快照（防抖）。
--
-- 为什么需要：KOReader 只在「设置了自动保存间隔」时才会在翻页后调用 saveSettings()
-- （见 readerview.lua 的 settings_last_save_time 逻辑），默认不开。
-- 也就是说，如果用户一直读不关书，进度可能长时间只存在内存里，
-- 一旦崩溃/断电就丢。这里自己按时间节流，把进度定期写进插件 JSON。
-- 插件 JSON 是整表覆盖写，开销很小，不会像 flush 整个 doc_settings 那么重。
function WebDavReader:_scheduleProgressSnapshot()
    if self._snapshot_scheduled then return end
    self._snapshot_scheduled = true
    UIManager:scheduleIn(self.PROGRESS_SNAPSHOT_INTERVAL or 60, function()
        self._snapshot_scheduled = false
        if Session.current then
            self:saveCurrentProgress("periodic")
        end
    end)
end

--- Reader 翻页时触发（ReaderUI 会把 PageUpdate 广播给所有注册模块）。
function WebDavReader:onPageUpdate(page)
    if not Session.current then return end
    self._page_update_count = (self._page_update_count or 0) + 1
    -- 每 N 页做一次快照，兼顾「不丢太多」与「不频繁写盘」
    if self._page_update_count % (self.PROGRESS_SNAPSHOT_EVERY or 10) == 0 then
        self:_scheduleProgressSnapshot()
    end
end

--- Reader 滚动模式的位置更新。
-- 注意 PosUpdate 在滚动时触发极频繁（每帧都可能），必须按时间节流，
-- 不能只靠 scheduleIn（它不会因为重复调用而重置）。
function WebDavReader:onPosUpdate(pos, page)
    if not Session.current then return end
    local now = os.time()
    local last = self._last_pos_snapshot or 0
    if now - last >= (self.PROGRESS_SNAPSHOT_INTERVAL or 60) then
        self._last_pos_snapshot = now
        self:_scheduleProgressSnapshot()
    end
end

function WebDavReader:onCloseDocument()
    if not Session.current then return end
    self:saveCurrentProgress("CloseDocument")
    local remote = Session.current
    local return_to_browser = Config:getReturnToBrowser()
    local keep_cache = Config:getKeepCache()
    Session.clearCurrent()

    if not keep_cache then
        -- 延迟清理，避免 Reader 仍在读文件
        UIManager:scheduleIn(2, function()
            Cache:invalidate(remote.server, remote.remote_path)
        end)
    end
    if return_to_browser then
        local server_idx
        for i, srv in ipairs(Config:getServers()) do
            if srv.address == remote.server.address then
                server_idx = i
                break
            end
        end
        if server_idx then
            UIManager:scheduleIn(0.3, function()
                self:_reopenBrowserAfterReaderClosed(server_idx)
            end)
        end
    end
end

--- 关书后重新打开浏览界面。
--
-- 关键点：不能复用 ReaderUI 这份插件实例去打开文件。
-- ReaderUI:onClose 的顺序是 handleEvent(CloseDocument) -> closeDocument()（把 self.document 置 nil）
-- -> UIManager:close(dialog)。等定时器跑到时 ReaderUI 已经拆干净了，
-- 若此时再用它去开放文件，filemanagerutil.openFile 会走到 else 分支调用 ui:openFile(...)，
-- 而 ReaderUI 根本没有 openFile 方法（只有 FileManager 有），第二次打开必崩。
--
-- 因此这里借助 UIManager 的广播：FileManager 那份插件实例（仍存活）会收到该事件并负责
-- 用 FileManager 的 ui 打开浏览器界面。
function WebDavReader:_reopenBrowserAfterReaderClosed(server_idx)
    -- 如果本实例自己就是 FileManager 上下文（ui.file_chooser 存在），直接开即可
    if self.ui and self.ui.file_chooser then
        self:openBrowserFor(server_idx)
        return
    end

    -- Reader 上下文：交给 FileManager 实例处理
    local ok = pcall(function()
        UIManager:broadcastEvent(require("ui/event"):new("ShowWebDavReaderBrowser", server_idx))
    end)
    if not ok then
        -- 广播失败（例如 FileManager 也关了）：退化为在当前实例打开，
        -- 至少界面能出现；此时用户重新点文件会走本实例的 openRemoteFile。
        logger.warn("webdavreader: 广播打开事件失败，改为就地打开")
        self:openBrowserFor(server_idx)
    end
end

--------------------------------------------------------------------------------
-- 状态持久化（记住上次浏览位置与缓存映射）
--------------------------------------------------------------------------------

function WebDavReader:getStatePath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/webdavreader_state.lua"
end

--- 读取一个状态项。
function WebDavReader:readSetting(key)
    local data = self:readState()
    return data and data[key]
end

--- 写入一个状态项（立即落盘，状态量很小）。
function WebDavReader:writeSetting(key, value)
    local data = self:readState() or {}
    data[key] = value
    self:writeState(data)
end

function WebDavReader:readState()
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (lfs_ok and lfs.attributes(self:getStatePath(), "mode") == "file") then
        return nil
    end
    local chunk = loadfile and loadfile(self:getStatePath())
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

--- 序列化（只支持字符串/数字/布尔与字符串浅表，足够本插件状态用）。
local function serializeValue(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = { "{" }
        local keys = {}
        for k in pairs(v) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for key_idx, k in ipairs(keys) do
            table.insert(parts, string.format("[%q] = %s,", tostring(k), serializeValue(v[k])))
        end
        table.insert(parts, "}")
        return table.concat(parts)
    end
    return "nil"
end

function WebDavReader:writeState(data)
    local parts = { "return {" }
    local keys = {}
    for k in pairs(data) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for key_idx, k in ipairs(keys) do
        table.insert(parts, string.format("[%q] = %s,", k, serializeValue(data[k])))
    end
    table.insert(parts, "}")
    local fh = io.open(self:getStatePath(), "w")
    if fh then
        fh:write(table.concat(parts, "\n"))
        fh:close()
    end
end

function WebDavReader:loadState()
    local data = self:readState()
    if not data then return end
    Session.last_server_idx = data.last_server_idx
    Session.last_paths = data.last_paths or {}
    Session.loadMap(data.local_map)
end

--- 把会话状态合并进状态文件（读-改-写，而不是整表覆盖）。
--
-- 这里必须做合并：同一个 webdavreader_state.lua 里还存着排序偏好
-- （sort_key / sort_descending / sort_folders_first）。早先的实现直接
-- writeState{ last_server_idx=..., last_paths=..., local_map=... } 整表覆盖，
-- 于是「打开一本书」这个动作（openRemoteFile 会调 saveState）顺手把用户的
-- 排序设置抹掉了 —— 表现为「切完排序、一读书就变回默认」。
function WebDavReader:saveState()
    local data = self:readState() or {}
    -- 只在内存里有值时覆盖：把 nil 赋给 table 的键等于删除该键，
    -- 若某条调用路径上 Session 还没初始化，就会顺手抹掉磁盘里已有的值。
    if Session.last_server_idx ~= nil then
        data.last_server_idx = Session.last_server_idx
    end
    if Session.last_paths ~= nil then
        data.last_paths = Session.last_paths
    end
    data.local_map = Session.exportMap()
    self:writeState(data)
end

--------------------------------------------------------------------------------
-- 设置保存
--------------------------------------------------------------------------------

function WebDavReader:onFlushSettings()
    Config:save()
    Progress:flush()
    History:flush()
    self:saveState()
end

return WebDavReader
