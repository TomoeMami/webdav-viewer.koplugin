-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
远程浏览界面：在 KOReader 里浏览 WebDAV 上的文本文件

界面结构（继承 BookList / Menu）：
  ┌──────────────────────────────┐
  │ 服务器名            当前路径  │  <- 标题栏
  ├──────────────────────────────┤
  │ 📁 子目录/          [3 项]   │  <- 点击进入
  │ 📄 三体.txt         42%  2MB │  <- 点击：下载到临时目录并打开阅读
  │ ...                          │     长按：删除 / 移动 / 重命名 / 详情
  └──────────────────────────────┘
  左按钮：上一级 / 菜单      右按钮：刷新

与官方 cloudstorage 插件的区别（本插件的核心设计）：
  * 不需要用户指定本地下载目录：远程文件直接下载到插件自己的临时缓存，
    打开阅读时不走「先选目录再保存」的流程；
  * 进度不依赖 KOReader 的 sidecar，而是写入本插件独有的 JSON，
    键为「服务器 + 远程路径 + 文件名」，因此缓存被清空也能恢复进度；
  * 界面内置删除 / 移动 / 重命名等远程文件管理操作。

@module koplugin.webdavreader.browser
--]]--

local BD = require("ui/bidi")
local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Notification = require("ui/widget/notification")
local PathChooser = require("ui/widget/pathchooser")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Store = require("wdr.store")

local Browser = BookList:extend{
    -- 由 main.lua 注入
    plugin = nil,
    config = nil,
    progress = nil,
    cache = nil,
    manager = nil,

    collate = "strcoll",
    path = "",           -- 当前远程路径（相对，无前导斜杠）
    server_idx = nil,
    paths = nil,         -- 已访问路径栈，用于返回上级
    item_table = nil,
    is_borderless = true,
    is_popout = false,
    -- 进入目录后回到原位置
    item_idx_stack = nil,
    show_progress = true,
}

local collates = {
    strcoll = {
        text = _("name"),
        sort_func = BookList.getCollateSortFunc(),
    },
    name = {
        text = _("name (natural)"),
        sort_func = BookList.getCollateSortFunc("natural"),
    },
    size = {
        text = _("size"),
        sort_func = function(a, b)
            if a.is_file and b.is_file then
                return (a.filesize or 0) < (b.filesize or 0)
            end
            return ffiUtil.strcoll(a.text, b.text)
        end,
    },
    date = {
        text = _("date modified"),
        sort_func = function(a, b)
            if a.is_file and b.is_file and a.modification and b.modification then
                return a.modification > b.modification
            end
            return ffiUtil.strcoll(a.text, b.text)
        end,
    },
}

--------------------------------------------------------------------------------
-- 生命周期
--------------------------------------------------------------------------------

function Browser:init()
    -- 注意：这里不能调用 self:setTitleBarLeftIcon()：
    -- Menu:setTitleBarLeftIcon 会访问 self.title_bar，而 title_bar 要到
    -- BookList.init -> Menu.init 里才创建，此刻还是 nil，会直接崩。
    -- 左侧按钮通过构造参数 title_bar_left_icon 声明（见 main.lua 的 Browser:new）。
    self.item_idx_stack = {}
    self.item_table = {}
    self.onLeftButtonTap = function()
        self:showFolderMenu()
    end
    self.onLeftButtonHold = function()
        self:onReturn()
    end

    BookList.init(self)

    -- 必须放在 BookList.init 之后：Menu.init 会无条件把 self.paths 重置为 {}，
    -- 那是 Menu 自己用来追踪导航的表。我们用独立的 dir_stack，避免被覆盖。
    self.dir_stack = self.dir_stack or { "" }
end

--- 由 main.lua 调用：打开指定服务器的起始目录。
function Browser:openServer(server_idx)
    self.server_idx = server_idx
    self.dir_stack = { "" }
    local server = self.config:getServer(server_idx)
    if not server then return end
    local start = Store.normalizeDir(server.start_dir)
    self:enterPath(start, true)
end

--------------------------------------------------------------------------------
-- 加载目录
--------------------------------------------------------------------------------

--- 加载并展示某个远程目录。
-- @param path string 相对路径
-- @param do_show boolean|nil 是否显示界面（首次进入时为 true）
function Browser:enterPath(path, do_show)
    local server = self.config:getServer(self.server_idx)
    if not server then
        UIManager:show(InfoMessage:new{ text = _("服务器配置不存在。") })
        return
    end

    local client, err = self.plugin:getClientFor(server)
    if not client then
        UIManager:show(InfoMessage:new{
            text = T(_("无法连接服务器：\n%1"), err or _("未知错误")),
            timeout = 4,
        })
        return
    end

    -- 请求是同步的（luasocket），服务器慢时整个界面会卡住，
    -- 所以先让用户看到「正在读取」的反馈，并把界面画出来。
    local loading = InfoMessage:new{
        text = T(_("正在读取 /%1 …"), path == "" and "" or path),
        timeout = 30,
    }
    UIManager:show(loading)
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end

    local items, list_err = client:list(path)
    UIManager:close(loading)

    if not items then
        -- 首次进入失败时按「起始目录 -> 根目录」再试，避免一次失败就什么都出不来
        if do_show and not self._fallback_tried then
            self._fallback_tried = true
            local candidates = {}
            local start = Store.normalizeDir(server.start_dir or "")
            if start ~= "" and start ~= path then table.insert(candidates, start) end
            if path ~= "" then table.insert(candidates, "") end
            for _, candidate in ipairs(candidates) do
                local retry_items = client:list(candidate)
                if retry_items then
                    self._fallback_tried = nil
                    self.path = candidate
                    self:buildItemTable(retry_items, candidate)
                    local subtitle = candidate == "" and "/" or "/" .. candidate
                    self:switchItemTable(server.name or "WebDAV", self.item_table, nil, nil, subtitle)
                    UIManager:show(self)
                    UIManager:show(InfoMessage:new{
                        text = T(_("无法打开请求的目录，已回到 /%1"),
                            candidate == "" and "" or candidate),
                        timeout = 3,
                    })
                    return
                end
            end
            self._fallback_tried = nil
        end

        UIManager:show(InfoMessage:new{
            text = T(_("无法读取目录内容：\n%1"), list_err or _("未知错误")),
            timeout = 4,
        })
        -- 回退到上一级（若有）
        if do_show and #self.dir_stack > 1 then
            table.remove(self.dir_stack)
            self:enterPath(self.dir_stack[#self.dir_stack])
        end
        return
    end

    self.path = path
    self:buildItemTable(items, path)

    local title = server.name or _("WebDAV")
    local subtitle = path == "" and "/" or "/" .. path
    if do_show then
        self:switchItemTable(title, self.item_table, nil, nil, subtitle)
        UIManager:show(self)
    else
        self:switchItemTable(title, self.item_table, nil, nil, subtitle)
        self:updateItems(1, true)
    end
    -- 此处 title_bar 已由 Menu:init 创建，可以安全设置左侧图标
    self:setTitleBarLeftIcon("plus")
end

--- 把服务器返回的原始条目转成 Menu 的可显示项。
function Browser:buildItemTable(items, path)
    local server = self.config:getServer(self.server_idx)
    local tbl = {}

    for _, it in ipairs(items or {}) do
        if it.is_folder then
            table.insert(tbl, {
                text = "📁 " .. it.name,
                is_folder = true,
                remote_path = it.path or Store.joinRemotePath(path, it.name),
                name = it.name,
            })
        else
            local entry = self.progress:get(server, it.path or Store.joinRemotePath(path, it.name))
            local progress_text = self.progress.formatEntry(entry)
            local size_text = it.size and util.getFriendlySize(it.size) or ""
            local mandatory_parts = {}
            if progress_text then
                table.insert(mandatory_parts, "★" .. progress_text)
            end
            if size_text ~= "" then
                table.insert(mandatory_parts, size_text)
            end
            table.insert(tbl, {
                text = "📄 " .. it.name,
                is_file = true,
                is_folder = false,
                remote_path = it.path or Store.joinRemotePath(path, it.name),
                name = it.name,
                filesize = it.size,
                modification = it.modified,
                progress_entry = entry,
                progress_text = progress_text,
                mandatory = table.concat(mandatory_parts, "  "),
            })
        end
    end

    self:sortItemTable(tbl)
    self.item_table = tbl
    return tbl
end

function Browser:sortItemTable(tbl)
    local sort_func
    local coll = collates[self.collate]
    if coll then
        sort_func = coll.sort_func
    else
        sort_func = collates.strcoll.sort_func
    end
    table.sort(tbl, function(a, b)
        if a.is_folder ~= b.is_folder then
            return a.is_folder -- 目录优先
        end
        if a.is_file and b.is_file then
            return sort_func(a, b)
        end
        return ffiUtil.strcoll(a.name or a.text, b.name or b.text)
    end)
end

--------------------------------------------------------------------------------
-- 交互：单击
--------------------------------------------------------------------------------

function Browser:onMenuSelect(item)
    if item.is_folder then
        self.dir_stack[#self.dir_stack + 1] = item.remote_path
        self:enterPath(item.remote_path)
    elseif item.is_file then
        self:openFile(item)
    end
    return true
end

--- 打开远程文件：确保本地有缓存 -> 应用插件进度 -> 用 KOReader 打开。
function Browser:openFile(item)
    local server = self.config:getServer(self.server_idx)
    if not server then return end

    -- 打开前把当前进度落盘（防止快速切换时丢失）
    self.progress:flush()

    local local_path = self.cache:getLocalPath(server, item.remote_path)
    if not local_path then
        UIManager:show(InfoMessage:new{ text = _("缓存目录不可用。") })
        return
    end

    if not DocumentRegistry:hasProvider(item.name) then
        UIManager:show(InfoMessage:new{
            text = T(_("KOReader 不支持打开这种文件：\n%1"), item.name),
            timeout = 3,
        })
        return
    end

    -- 已缓存且大小一致则直接打开，不重复下载（省流量、秒开）
    if self.cache:isFresh(server, item.remote_path, item.filesize, item.modification) then
        self.cache:touch(server, item.remote_path)
        self.plugin:openRemoteFile(server, item, local_path)
        return
    end

    self:downloadAndOpen(server, item, local_path)
end

function Browser:downloadAndOpen(server, item, local_path)
    self.cache:ensureDir()
    local progressbar = ProgressbarDialog:new{
        title = _("正在下载…"),
        subtitle = item.name,
        progress_max = item.filesize,
    }

    UIManager:scheduleIn(0.1, function()
        local client = self.plugin:getClientFor(server)
        if not client then
            progressbar:close()
            UIManager:show(InfoMessage:new{ text = _("无法连接服务器。"), timeout = 3 })
            return
        end
        local total = nil
        local ok, err = client:download(item.remote_path, local_path, {
            progress_cb = function(downloaded, file_total)
                if file_total then total = file_total end
                progressbar:reportProgress(downloaded)
            end,
        })
        progressbar:close()
        if not ok then
            os.remove(local_path)
            UIManager:show(InfoMessage:new{
                text = T(_("下载失败：\n%1"), err or _("未知错误")),
                timeout = 4,
            })
            return
        end
        -- 下载完成后再校验一次大小
        local expected = item.filesize
        local actual = lfs.attributes(local_path, "size")
        if expected and actual and expected ~= actual then
            logger.warn("webdavreader: 下载大小不一致", expected, actual)
        end
        self.cache:touch(server, item.remote_path)
        self.cache:markDownloaded(server, item.remote_path, item.filesize, item.modification)
        -- 每次下载后按上限淘汰旧缓存，避免缓存目录无限增长把分区撑满
        pcall(function()
            self.cache:prune(self.config:getMaxCacheMB())
        end)
        self.plugin:openRemoteFile(server, item, local_path)
    end)
    progressbar:show()
end

--------------------------------------------------------------------------------
-- 交互：长按（文件管理）
--------------------------------------------------------------------------------

function Browser:onMenuHold(item)
    self.file_dialog = ButtonDialog:new{
        title = item.is_folder and (item.name .. "/") or item.name,
        title_align = "center",
        buttons = item.is_folder and self:getFolderButtons(item) or self:getFileButtons(item),
    }
    UIManager:show(self.file_dialog)
    return true
end

function Browser:getFileButtons(item)
    local buttons = {
        {
            {
                text = _("打开"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:openFile(item)
                end,
            },
            {
                text = _("详情"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:showFileInfo(item)
                end,
            },
        },
        {
            {
                text = _("重命名"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:showRenameDialog(item)
                end,
            },
            {
                text = _("移动"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:showMoveDialog(item)
                end,
            },
        },
        {},
        {
            {
                text = _("删除"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:confirmDelete(item)
                end,
            },
        },
    }
    return buttons
end

function Browser:getFolderButtons(item)
    local buttons = {
        {
            {
                text = _("进入"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self.dir_stack[#self.dir_stack + 1] = item.remote_path
                    self:enterPath(item.remote_path)
                end,
            },
            {
                text = _("重命名"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:showRenameDialog(item)
                end,
            },
        },
        {
            {
                text = _("移动"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:showMoveDialog(item)
                end,
            },
        },
        {},
        {
            {
                text = _("删除目录"),
                callback = function()
                    UIManager:close(self.file_dialog)
                    self:confirmDeleteFolder(item)
                end,
            },
        },
    }
    return buttons
end

function Browser:showFileInfo(item)
    local server = self.config:getServer(self.server_idx)
    local entry = self.progress:get(server, item.remote_path)
    local lines = {
        item.name,
        "",
        T(_("路径：%1"), "/" .. (item.remote_path or "")),
    }
    if item.filesize then
        table.insert(lines, T(_("大小：%1"), util.getFriendlySize(item.filesize)))
    end
    if item.modification then
        table.insert(lines, T(_("修改时间：%1"),
            os.date("%Y-%m-%d %H:%M", item.modification)))
    end
    if entry then
        if entry.percent then
            table.insert(lines, T(_("阅读进度：%1"), string.format("%d%%", math.floor(entry.percent * 100 + 0.5))))
        end
        if entry.updated then
            table.insert(lines, T(_("进度更新：%1"),
                os.date("%Y-%m-%d %H:%M", entry.updated)))
        end
    else
        table.insert(lines, _("阅读进度：无"))
    end
    local local_path = self.cache:getLocalPath(server, item.remote_path)
    local cached = local_path and lfs.attributes(local_path, "mode") == "file"
    table.insert(lines, cached and _("本地缓存：有") or _("本地缓存：无"))

    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--------------------------------------------------------------------------------
-- 删除
--------------------------------------------------------------------------------

function Browser:confirmDelete(item)
    UIManager:show(ConfirmBox:new{
        text = T(_("确定删除远程文件？\n\n%1"), item.name) .. "\n\n" ..
               _("此操作不可恢复；该文件的本地缓存与阅读进度也会一并清除。"),
        ok_text = _("删除"),
        ok_callback = function()
            self:doDelete(item)
        end,
    })
end

function Browser:doDelete(item)
    local server = self.config:getServer(self.server_idx)
    local ok, err = self.manager:deleteFile(server, item.remote_path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("删除失败：\n%1"), err or _("未知错误")),
            timeout = 4,
        })
        return
    end
    UIManager:show(Notification:new{
        text = T(_("已删除 %1"), item.name),
        timeout = 2,
    })
    self:enterPath(self.path)
end

function Browser:confirmDeleteFolder(item)
    local server = self.config:getServer(self.server_idx)
    local files, folders, err = self.manager:countFolderItems(server, item.remote_path)
    if not files then
        UIManager:show(InfoMessage:new{
            text = T(_("读取目录失败：\n%1"), err or _("未知错误")),
            timeout = 4,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("确定删除目录？\n\n%1"), item.name) .. "\n\n" ..
               T(_("目录内含 %1 个文件、%2 个子目录，将全部被删除且不可恢复。"), files, folders),
        ok_text = _("删除"),
        ok_callback = function()
            local ok2, del_err = self.manager:deleteFolder(server, item.remote_path)
            if not ok2 then
                UIManager:show(InfoMessage:new{
                    text = T(_("删除目录失败：\n%1"), del_err or _("未知错误")),
                    timeout = 4,
                })
                return
            end
            UIManager:show(Notification:new{
                text = T(_("已删除目录 %1"), item.name),
                timeout = 2,
            })
            self:enterPath(self.path)
        end,
    })
end

--------------------------------------------------------------------------------
-- 重命名 / 移动
--------------------------------------------------------------------------------

function Browser:showRenameDialog(item)
    local dialog
    dialog = InputDialog:new{
        title = T(_("重命名：%1"), item.name),
        input = item.name,
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
                        local new_name = dialog:getInputText()
                        UIManager:close(dialog)
                        self:doRename(item, new_name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:doRename(item, new_name)
    new_name = util.trim(new_name or "")
    if new_name == "" or new_name == item.name then
        return
    end
    local ok, err = self.manager:validateName(new_name)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("名称无效：\n%1"), err or ""),
            timeout = 3,
        })
        return
    end

    local server = self.config:getServer(self.server_idx)
    local ok2, new_path, err2
    if item.is_folder then
        local parent = Store.getRemoteDir(item.remote_path)
        new_path = Store.joinRemotePath(parent, new_name)
        ok2, err2 = self.manager:moveItem(server, item.remote_path, new_path)
    else
        ok2, new_path, err2 = self.manager:renameFile(server, item.remote_path, new_name)
    end

    if not ok2 then
        UIManager:show(InfoMessage:new{
            text = T(_("重命名失败：\n%1"), err2 or _("未知错误")),
            timeout = 4,
        })
        return
    end
    UIManager:show(Notification:new{
        text = T(_("已重命名为 %1"), new_name),
        timeout = 2,
    })
    self:enterPath(self.path)
end

--- 移动对话框：输入目标目录的相对路径（相对服务器根）。
function Browser:showMoveDialog(item)
    local dialog
    local hint = _("目标目录（相对服务器根，留空表示根目录）")
    dialog = InputDialog:new{
        title = T(_("移动到：%1"), item.name),
        description = hint .. "\n\n" .. T(_("当前路径：/%1"), item.remote_path),
        input = Store.getRemoteDir(item.remote_path),
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
                    text = _("移动"),
                    is_enter_default = true,
                    callback = function()
                        local target_dir = dialog:getInputText()
                        UIManager:close(dialog)
                        self:doMove(item, target_dir)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:doMove(item, target_dir)
    local server = self.config:getServer(self.server_idx)
    target_dir = Store.normalizeDir(util.trim(target_dir or ""))
    local new_path = Store.joinRemotePath(target_dir, item.name)
    if new_path == item.remote_path then
        return
    end
    local ok, err = self.manager:moveItem(server, item.remote_path, new_path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("移动失败：\n%1"), err or _("未知错误")),
            timeout = 4,
        })
        return
    end
    UIManager:show(Notification:new{
        text = T(_("已移动到 /%1"), new_path),
        timeout = 2,
    })
    self:enterPath(self.path)
end

--------------------------------------------------------------------------------
-- 目录级操作
--------------------------------------------------------------------------------

function Browser:showFolderMenu()
    local buttons = {
        {
            {
                text = _("上一级"),
                enabled = #self.dir_stack > 1,
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:onReturn()
                end,
            },
            {
                text = _("刷新"),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:enterPath(self.path)
                end,
            },
        },
        {
            {
                text = _("新建文件夹"),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:showCreateFolderDialog()
                end,
            },
        },
        {},
        {
            {
                text = T(_("排序：%1"), (collates[self.collate] or collates.strcoll).text),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:showSortDialog()
                end,
            },
        },
        {},
        {
            {
                text = _("切换服务器"),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:onClose()
                    self.plugin:showServerList(true)
                end,
            },
            {
                text = _("缓存设置"),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self.plugin:showCacheDialog()
                end,
            },
        },
    }
    self.folder_menu = ButtonDialog:new{ buttons = buttons }
    UIManager:show(self.folder_menu)
end

function Browser:showSortDialog()
    local buttons = {}
    for key, coll in pairs(collates) do
        table.insert(buttons, {
            {
                text = (self.collate == key and "✓ " or "") .. coll.text,
                callback = function()
                    UIManager:close(self.sort_dialog)
                    self.collate = key
                    self:sortItemTable(self.item_table)
                    self:updateItems(1, true)
                end,
            },
        })
    end
    table.sort(buttons, function(a, b) return a[1].text < b[1].text end)
    self.sort_dialog = ButtonDialog:new{ title = _("排序方式"), buttons = buttons }
    UIManager:show(self.sort_dialog)
end

function Browser:showCreateFolderDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("新建文件夹"),
        description = T(_("在 /%1 下创建"), self.path == "" and "" or self.path),
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
                    text = _("创建"),
                    is_enter_default = true,
                    callback = function()
                        local name = util.trim(dialog:getInputText())
                        UIManager:close(dialog)
                        self:doCreateFolder(name)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:doCreateFolder(name)
    if name == "" then return end
    local server = self.config:getServer(self.server_idx)
    local ok, new_path, err = self.manager:createFolder(server, self.path, name)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("创建文件夹失败：\n%1"), err or _("未知错误")),
            timeout = 4,
        })
        return
    end
    UIManager:show(Notification:new{ text = T(_("已创建 /%1"), new_path or name), timeout = 2 })
    self:enterPath(self.path)
end

--------------------------------------------------------------------------------
-- 导航
--------------------------------------------------------------------------------

function Browser:onReturn()
    if #self.dir_stack > 1 then
        table.remove(self.dir_stack)
        self:enterPath(self.dir_stack[#self.dir_stack])
    else
        self:onClose()
    end
    return true
end

--- 关闭时把进度写盘，并把控制权交回基类。
function Browser:onCloseWidget()
    self.progress:flush()
    if BookList.onCloseWidget then
        BookList.onCloseWidget(self)
    end
end

return Browser
