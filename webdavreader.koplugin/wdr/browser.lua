-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
远程浏览界面：在 KOReader 里浏览 WebDAV 上的文本文件

界面结构（继承 BookList / Menu）：
  ┌──────────────────────────────┐
  │ 服务器名      当前路径 · 排序 │  <- 标题栏（副标题带当前排序方式）
  ├──────────────────────────────┤
  │ 📁 子目录/          [3 项]   │  <- 点击进入
  │ 📄 三体.txt         42%  2MB │  <- 点击：下载到临时目录并打开阅读
  │ ...                          │     长按：删除 / 移动 / 重命名 / 详情
  └──────────────────────────────┘
  左按钮：目录菜单（上一级 / 刷新 / 排序 / 新建文件夹 / 切换服务器 / 缓存设置）
          长按左按钮：直接返回上一级

排序：
  * 目录页面左上角菜单里的「排序」可切换 名称 / 名称（自然）/ 修改时间 /
    创建时间 / 大小 / 类型，并可切换 升序 / 降序 与「目录优先」；
  * 选择会写进插件状态（webdavreader_state.lua），下次进入沿用上次的选择；
  * 目录之间始终按名称排序，日期/大小只作用于文件；
  * 按时间排序时，列表右侧会顺带显示对应日期，便于核对。

移动历史：
  * 「移动」先弹出最近用过的目标目录，点一下即可移动；
  * 目标目录记在 webdavreader_history.json，按服务器隔离，最多 20 条（界面显示 8 条）；
  * 只有在移动**成功**后才记入历史；「其他位置…」仍可手动输入任意目录。

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

local History = require("wdr.history")
local Sort = require("wdr.sort")
local Store = require("wdr.store")

local Browser = BookList:extend{
    -- 由 main.lua 注入
    plugin = nil,
    config = nil,
    progress = nil,
    cache = nil,
    manager = nil,

    -- 排序状态。由 main.lua 从插件状态里恢复；排序变化时回写。
    --   sort_key        见 wdr/sort.lua 的 Sort.keys
    --   sort_descending 用户看到的方向（true=降序）；与各键自身默认方向无关
    --   sort_folders_first 目录是否始终排在文件前面
    sort_key = Sort.DEFAULT_KEY,
    sort_descending = false,
    sort_folders_first = true,

    path = "",           -- 当前远程路径（相对，无前导斜杠）
    server_idx = nil,
    paths = nil,         -- 已访问路径栈，用于返回上级
    item_table = nil,
    is_borderless = true,
    is_popout = false,
    -- 进入目录后回到原位置
    item_idx_stack = nil,
    show_progress = true,
    -- 移动对话框里最多列出多少条历史目标（存储层最多保留 20 条）
    MOVE_HISTORY_LIMIT = 8,
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

    -- 让 Menu 的「返回上一级」箭头（左下角）可用。
    --
    -- 为什么需要这一句：Menu:updatePageInfo 里有一行
    --     self.page_return_arrow:enableDisable(#self.paths > 0)
    -- 即箭头是否可点，完全由 Menu 自己的 self.paths 决定。而本插件从来不用 self.paths
    -- 做导航（Menu:init 会把它重置为 {}，我们用独立的 dir_stack），所以它永远是空表，
    -- 于是箭头虽然显示出来，却永远处于 disabled 状态 —— 点下去毫无反应。
    --
    -- dir_stack 与 paths 在这里恰好语义一致（都表示「可以往上走」），所以让 paths
    -- 跟随 dir_stack 即可，不必改动 Menu。KOReader 官方 filemanagercollection.lua:109
    -- 用的也是同一手法（table.insert(self.booklist_menu.paths, true)）。
    self:syncMenuPaths()
end

--- 把 dir_stack 的「可返回性」同步给 Menu 的 self.paths，用于启用左下角返回箭头。
--
-- 只在两种状态间取值：根目录（栈深 1）→ 空表，可返回 → 单元素表。
-- 不直接把 dir_stack 赋给 paths：Menu 会在 updatePageInfo 里读 #self.paths，
-- 只需要「有没有」这个布尔信息，复用一个短表既够用又不会让 Menu 的内部状态变复杂。
function Browser:syncMenuPaths()
    local can_go_up = self.dir_stack and #self.dir_stack > 1
    if can_go_up then
        if #self.paths == 0 then
            self.paths[1] = true
        end
    elseif #self.paths > 0 then
        -- 从子目录回到根目录后要重新禁用箭头，不能只 insert 不清理
        self.paths = {}
    end
end

--- 由 main.lua 调用：打开指定服务器的起始目录。
function Browser:openServer(server_idx)
    self.server_idx = server_idx
    self.dir_stack = { "" }
    local server = self.config:getServer(server_idx)
    if not server then return end
    local start = Store.normalizeDir(server.start_dir)
    self:openPathAt(start, true)
end

--- 直接跳到某个深层目录，并按路径段数重建导航栈。
--
-- 为什么必须有这个函数：直接调用 enterPath(path) 只会改变 self.path，
-- 而 dir_stack 仍是 { "" }。于是「返回上一级」的所有判据（#dir_stack > 1）全为假：
--   * buildItemTable 不插入「⬆ ../」置顶行；
--   * syncMenuPaths 让左下角箭头保持 disabled；
--   * 目录菜单里的「上一级」是灰的；
--   * onReturn 还会走进 onClose() 分支 —— 在深层目录里按返回等于直接关掉界面。
-- 典型触发点就是「记住上次浏览位置」：用户上次在 books/deep，重开却一条退路都没有。
--
-- 修复方式：把目标路径按 "/" 拆段，逐级压栈（根是 ""，所以 N 段目录对应 N+1 个元素），
-- 这样 dir_stack 与 self.path 始终自洽。
-- @param path string 相对路径（"" 表示根目录）
-- @param do_show boolean|nil 是否显示界面
function Browser:openPathAt(path, do_show)
    path = Store.normalizeDir(path)
    self:rebuildDirStack(path)
    self:enterPath(path, do_show)
end

--- 按路径的层级重建 dir_stack（根 "" + 每一段目录）。
-- 单独抽出来是因为「进入失败后回退到起始目录」也要把栈对齐到实际路径，
-- 不能让栈指向一个已经不存在的层级。
-- @param path string 相对路径
-- @return table 重建后的 dir_stack
function Browser:rebuildDirStack(path)
    path = Store.normalizeDir(path)
    self.dir_stack = { "" }
    if path == "" then return self.dir_stack end
    local acc = ""
    for seg in path:gmatch("[^/]+") do
        acc = acc == "" and seg or (acc .. "/" .. seg)
        self.dir_stack[#self.dir_stack + 1] = acc
    end
    return self.dir_stack
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
            -- 循环变量不要用 "_"：本文件顶部有 local _ = require("gettext")，
            -- 用 "_" 当占位变量会把它遮蔽成 ipairs 的索引（数字），
            -- 于是分支里的 T(_("...")) 会抛 attempt to call local '_' (a number value)，
            -- 表现为「首次进入某目录失败需要回退时整个界面崩掉」。
            for candidate_idx, candidate in ipairs(candidates) do
                local retry_items = client:list(candidate)
                if retry_items then
                    self._fallback_tried = nil
                    self.path = candidate
                    self.raw_items = retry_items
                    -- 回退到的目录通常比原目标浅（起始目录或根），
                    -- dir_stack 必须跟着这个新路径重建，否则「返回上一级」
                    -- 会指向一个不存在的层级（甚至把栈弹空）。
                    self:rebuildDirStack(candidate)
                    self:buildItemTable(retry_items, candidate)
                    local retry_subtitle = self:getSubtitle()
                    self.subtitle = retry_subtitle
                    self:syncMenuPaths()
                    self:switchItemTable(server.name or "WebDAV", self.item_table,
                        nil, nil, retry_subtitle)
                    UIManager:show(self)
                    self:setTitleBarLeftIcon("appbar.menu")
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
    self.raw_items = items
    self:buildItemTable(items, path)

    local title = server.name or _("WebDAV")
    local subtitle = self:getSubtitle()
    -- 自己留存一份副标题：Menu:switchItemTable 只把它交给 title_bar，
    -- 不会回写 self.subtitle，留一份便于排序变更后重画（与断言）。
    self.subtitle = subtitle
    -- 必须在 switchItemTable 之前同步：它内部会调用 updateItems -> updatePageInfo，
    -- 而那一步会读 #self.paths 决定左下角返回箭头是否可点。
    self:syncMenuPaths()
    self:switchItemTable(title, self.item_table, nil, nil, subtitle)
    if do_show then
        UIManager:show(self)
    else
        self:updateItems(1, true)
    end
    -- 此处 title_bar 已由 Menu:init 创建，可以安全设置左侧图标。
    -- 该按钮打开目录菜单（含排序），图标保持汉堡菜单样式，不要改成别的图形，
    -- 否则用户会以为它是「新建」之类的操作。
    self:setTitleBarLeftIcon("appbar.menu")
end

--- 标题栏副标题：当前路径 + 当前排序方式。
-- 把排序状态放在这里，用户随时能看到「现在按什么排」，不必进菜单确认。
function Browser:getSubtitle()
    local path_text = self.path == "" and "/" or "/" .. self.path
    return path_text .. "  ·  " .. self:getSortSummary()
end

--- 当前排序的简短说明，如 "名称 ↑"。
function Browser:getSortSummary()
    local arrow = self.sort_descending and "↓" or "↑"
    return T(_("%1 %2"), Sort.getText(self.sort_key), arrow)
end

--- 组装传给 wdr/sort.lua 的排序参数。
function Browser:getSortOptions()
    return {
        key = self.sort_key,
        descending = self.sort_descending and true or false,
        folders_first = self.sort_folders_first ~= false,
    }
end

--- 把服务器返回的原始条目转成 Menu 的可显示项。
function Browser:buildItemTable(items, path)
    local server = self.config:getServer(self.server_idx)
    local tbl = {}
    local sort_key_info = Sort.KEY_BY_ID[self.sort_key] or Sort.KEY_BY_ID[Sort.DEFAULT_KEY]
    local show_date = sort_key_info and sort_key_info.date_based

    -- 置顶一行「返回上一级」。
    --
    -- 为什么需要它：底部左下角的返回箭头依赖 Menu:updatePageInfo 里的
    -- enableDisable(#self.paths > 0)，状态链路容易失效；而「怎么回到上一层」是
    -- 浏览目录时最高频的操作，不该只藏在一个小箭头或长按里。
    -- 用 KOReader 自己的 is_go_up 约定（filechooser.lua:266 的同款写法），
    -- 排序时由 wdr/sort.lua 把 is_go_up 固定在最前，不受排序方式影响。
    if self.dir_stack and #self.dir_stack > 1 then
        table.insert(tbl, {
            text = BD.mirroredUILayout() and BD.ltr("../ ⬆") or "⬆ ../",
            is_go_up = true,
            is_folder = false,
            is_file = false,
            name = "..",
            remote_path = self.dir_stack[#self.dir_stack - 1] or "",
        })
    end

    for item_idx, it in ipairs(items or {}) do
        if it.is_folder then
            table.insert(tbl, {
                text = "📁 " .. it.name,
                is_folder = true,
                is_file = false,
                remote_path = it.path or Store.joinRemotePath(path, it.name),
                name = it.name,
                modification = it.modified,
                created = it.created,
            })
        else
            local entry = self.progress:get(server, it.path or Store.joinRemotePath(path, it.name))
            local progress_text = self.progress.formatEntry(entry)
            local size_text = it.size and util.getFriendlySize(it.size) or ""
            local mandatory_parts = {}
            if progress_text then
                table.insert(mandatory_parts, "★" .. progress_text)
            end
            -- 按时间排序时把对应日期显示出来，方便核对排序结果（否则用户只看到名字在跳）
            if show_date then
                local stamp = sort_key_info.key == "created" and it.created or it.modified
                if stamp then
                    table.insert(mandatory_parts, os.date("%Y-%m-%d", stamp))
                end
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
                created = it.created,
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

--- 按当前排序状态给菜单项排序（原地）。
-- 具体比较规则见 wdr/sort.lua：目录优先、目录之间始终按名称、缺值项排最后。
function Browser:sortItemTable(tbl)
    Sort.sortItems(tbl, self:getSortOptions())
    return tbl
end

--- 排序状态改变后重画列表。
-- 用缓存的原始条目重建，而不是重新请求服务器：切排序不该产生网络开销。
function Browser:applySort()
    if self.raw_items then
        self:buildItemTable(self.raw_items, self.path)
    else
        self:sortItemTable(self.item_table)
    end
    self:refreshTitleSubtitle()
    if self.item_table then
        self:updateItems(1, true)
    end
end

--- 只更新标题栏副标题（路径没变、只是排序变了）。
function Browser:refreshTitleSubtitle()
    local subtitle = self:getSubtitle()
    self.subtitle = subtitle
    if self.title_bar and self.title_bar.setSubTitle then
        pcall(function() self.title_bar:setSubTitle(subtitle) end)
    end
end

--- 排序状态变化时回调插件，由 main.lua 写进插件状态文件。
-- 用回调而不是让 browser 直接碰持久化，保持界面层与存储层解耦。
function Browser:notifySortChanged()
    if type(self.on_sort_changed) == "function" then
        pcall(self.on_sort_changed, self.sort_key, self.sort_descending, self.sort_folders_first)
    end
end

--------------------------------------------------------------------------------
-- 交互：单击
--------------------------------------------------------------------------------

function Browser:onMenuSelect(item)
    -- 置顶的「返回上一级」行
    if item.is_go_up then
        self:onReturn()
    elseif item.is_folder then
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
    -- 「返回上一级」行没有可管理的内容（不能重命名/删除/移动它），
    -- 长按不弹菜单，避免出现一批对着它毫无意义的按钮。
    if item.is_go_up then
        return true
    end
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
    if item.created then
        table.insert(lines, T(_("创建时间：%1"),
            os.date("%Y-%m-%d %H:%M", item.created)))
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

--- 移动对话框：优先给出「最近用过的目标目录」，点一下即可移动。
--
-- 为什么不直接用输入框：移动时目标目录通常是最近用过的少数几个，
-- 手输一长串相对路径既慢又容易打错（打错还会得到「目标已存在」之类的报错）。
-- 因此这里先列历史，最后一个按钮仍是「其他位置…」进入手输，保留完整自由度。
function Browser:showMoveDialog(item)
    local server = self.config:getServer(self.server_idx)
    local current_dir = Store.getRemoteDir(item.remote_path)

    local entries = {}
    if server then
        local ok, list = pcall(History.list, History, server, self.MOVE_HISTORY_LIMIT or 8)
        if ok and type(list) == "table" then entries = list end
    end

    local buttons = {}
    for entry_idx, entry in ipairs(entries) do
        -- 当前所在目录不必列出：移到自己所在目录等于没动
        if entry.dir ~= current_dir then
            table.insert(buttons, {
                {
                    text = History.formatLabel(entry),
                    align = "left",
                    callback = function()
                        UIManager:close(self.move_dialog)
                        self:doMove(item, entry.dir)
                    end,
                },
            })
        end
    end

    if #buttons == 0 then
        -- 没有历史（或历史里只剩当前目录）时提示一句，免得用户以为按钮没加载。
        -- 不挂 callback：KOReader 的 Button 在 enabled=false 时不会触发点击
        -- （button.lua 的 onTapSelectButton 先判 enabled），只作为灰条提示用，
        -- 与官方（如 filemanagerbookinfo 的占位按钮）写法一致。
        table.insert(buttons, {
            {
                text = _("（暂无历史位置）"),
                enabled = false,
            },
        })
    end

    table.insert(buttons, {})
    table.insert(buttons, {
        {
            text = _("其他位置…"),
            callback = function()
                UIManager:close(self.move_dialog)
                self:showMoveInputDialog(item)
            end,
        },
    })

    self.move_dialog = ButtonDialog:new{
        title = T(_("移动到：%1"), item.name),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.move_dialog)
end

--- 手输目标目录的对话框（历史之外的兜底路径）。
function Browser:showMoveInputDialog(item)
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
        UIManager:show(Notification:new{
            text = _("已经在该目录里了"),
            timeout = 2,
        })
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
    -- 只有移动成功才记历史：否则用户点一个过期/无权限的目标后，
    -- 那个错误目标会一直排在快捷列表最前面，反而更难用。
    if server then
        pcall(History.add, History, server, target_dir)
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
                text = T(_("排序：%1"), self:getSortSummary()),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:showSortDialog()
                end,
            },
        },
        {
            {
                text = self.sort_folders_first ~= false and _("目录优先：开") or _("目录优先：关"),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:setSort(self.sort_key, self.sort_descending, self.sort_folders_first == false)
                end,
            },
            {
                text = self.sort_descending and _("方向：降序") or _("方向：升序"),
                callback = function()
                    UIManager:close(self.folder_menu)
                    self:setSort(self.sort_key, not self.sort_descending, self.sort_folders_first)
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
    self.folder_menu = ButtonDialog:new{
        title = self.path == "" and "/" or "/" .. self.path,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.folder_menu)
end

--- 切换排序状态：重建列表、刷新标题、并通知插件持久化。
-- @param key string 排序键（非法值由 Sort.resolve 兜底）
-- @param descending boolean|nil 方向（true=降序）
-- @param folders_first boolean|nil 目录是否优先
function Browser:setSort(key, descending, folders_first)
    local resolved = Sort.resolve(key)
    local changed = (resolved ~= self.sort_key)
        or ((descending and true or false) ~= (self.sort_descending and true or false))
        or ((folders_first ~= false) ~= (self.sort_folders_first ~= false))
    self.sort_key = resolved
    self.sort_descending = descending and true or false
    self.sort_folders_first = folders_first ~= false
    self:applySort()
    if changed then
        self:notifySortChanged()
    end
end

--- 排序方式选择对话框。
--
-- 交互设计（两点刻意的取舍）：
--   * 当前键前打 ✓，并且只有当前键显示「真实方向」箭头，其余键显示「选中后会变成的方向」，
--     这样用户点之前就知道点完会得到什么顺序；
--   * 再点一次当前键 = 翻转方向。排序键只有 6 个、方向只有 2 个，把「换键」和
--     「换方向」都塞进同一个列表，比再开一层子菜单少一次点击。
function Browser:showSortDialog()
    local buttons = {}
    for info_idx, info in ipairs(Sort.keys) do
        local is_current = (info.key == self.sort_key)
        local direction = is_current
            and (self.sort_descending and "↓" or "↑")
            or (info.descending and "↓" or "↑")
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "") .. Sort.getText(info.key) .. " " .. direction,
                callback = function()
                    UIManager:close(self.sort_dialog)
                    if is_current then
                        -- 再次点当前项 = 切换方向，省一次点击
                        self:setSort(info.key, not self.sort_descending, self.sort_folders_first)
                    else
                        self:setSort(info.key, info.descending and true or false, self.sort_folders_first)
                    end
                end,
            },
        })
    end
    -- 单独给出「目录优先」开关，避免只能靠记忆判断目录是否混排
    table.insert(buttons, {})
    table.insert(buttons, {
        {
            text = self.sort_folders_first ~= false and _("✓ 目录优先：开") or _("目录优先：关"),
            callback = function()
                UIManager:close(self.sort_dialog)
                self:setSort(self.sort_key, self.sort_descending, self.sort_folders_first == false)
            end,
        },
    })

    self.sort_dialog = ButtonDialog:new{
        title = _("排序方式"),
        title_align = "center",
        buttons = buttons,
    }
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

--- 返回上一级。
-- 栈已到根（#dir_stack == 1）时，这个动作的语义其实是「关掉浏览界面」，
-- 而不是「什么都不做」——之前的实现会让左下角箭头在根目录下点了毫无反馈，
-- 用户只会以为按钮坏了。这里改成关闭界面，与 KOReader 里「返回即退出」的直觉一致。
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
