--[[--
KOReader UI 组件仿真（供桌面 Lua 单测使用）

目标：让 main.lua / browser.lua 能在没有图形界面的桌面环境里被实例化和驱动，
用于验证「逻辑与接线」是否正确，而不是像素级外观。

仿真覆盖：
  ui/widget/container/widgetcontainer  WidgetContainer:extend/new
  ui/widget/menu                      Menu 基类（BookList 继承它）及 switchItemTable/updateItems
  ui/widget/booklist                  BookList 基类、排序函数
  ui/widget/buttondialog / confirmbox / infomessage / inputdialog / multiinputdialog /
  progressbardialog / notification      都是「记录参数」的假控件
  ui/uimanager                        show/close/scheduleIn/nextTick 立即执行
  ui/network/manager                  isOnline -> true
  dispatcher                          registerAction 记录到表
  document/documentregistry           hasProvider 按扩展名判断
  libs/libkoreader-lfs                转发真 lfs
  ui/bidi                             恒等函数

@module tests.ui_stubs
--]]--

local UIStubs = {}

--------------------------------------------------------------------------------
-- 被测试代码会读的全局表
--------------------------------------------------------------------------------

-- 记录所有 UIManager:show 过的控件与最近一条消息
UIManagerStub = {
    shown = {},
    last_widget = nil,
    last_message = nil,
    closed = {},
    scheduled = {},
}

function UIManagerStub.reset()
    UIManagerStub.shown = {}
    UIManagerStub.last_widget = nil
    UIManagerStub.last_message = nil
    UIManagerStub.closed = {}
    UIManagerStub.scheduled = {}
end

--- 收集一个假控件里所有可显示的文本（用于断言文案）。
function UIManagerStub.collect_texts(widget)
    local out = {}
    local seen = {}
    local function walk(t, depth)
        if type(t) ~= "table" or depth > 6 then return end
        if seen[t] then return end
        seen[t] = true
        for k, v in pairs(t) do
            if type(v) == "string" and (k == "text" or k == "title" or k == "hint"
                or k == "description" or k == "ok_text" or k == "input" or k == "subtitle") then
                out[#out + 1] = v
            elseif type(v) == "table" then
                walk(v, depth + 1)
            end
        end
    end
    walk(widget, 1)
    return out
end

-- 记录菜单注册
MenuRegistry = { last_items = {} }

function MenuRegistry.reset()
    MenuRegistry.last_items = {}
end

-- 记录 dispatcher 动作
ActionRegistry = { actions = {} }

function ActionRegistry.reset()
    ActionRegistry.actions = {}
end

--------------------------------------------------------------------------------
-- 基础控件类
--------------------------------------------------------------------------------

local EventListener = {}
EventListener.__index = EventListener

function EventListener:extend(subclass)
    local o = subclass or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function EventListener:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

function EventListener:handleEvent(event)
    if self[event.handler] then
        return self[event.handler](self, unpack(event.args or {}))
    end
end

local Widget = EventListener:extend{}

-- Menu 基类：只实现被测代码实际调用的方法
local Menu = Widget:extend{
    item_table = {},
    page = 1,
    collate = "strcoll",
    is_borderless = false,
    is_popout = true,
}

function Menu:init()
    self.item_table = self.item_table or {}
    self.item_table_stack = {}
    self.page = 1
    -- 如实模拟真实 Menu:init：无条件重置 paths，并在 init 内部才创建 title_bar
    self.paths = {}
    self.title_bar = setmetatable({
        has_left_icon = self.title_bar_left_icon ~= nil,
        left_icon = self.title_bar_left_icon,
    }, TitleBarStub)
end

function Menu:switchItemTable(new_title, new_item_table, itemnumber, itemmatch, new_subtitle)
    if new_item_table then
        self.item_table = new_item_table
        self.page = 1
    end
    self.title = new_title or self.title
    self.subtitle = new_subtitle or self.subtitle
    -- 记录到全局，便于断言
    SimpleTitleBarStub.last_title = self.title
    SimpleTitleBarStub.last_subtitle = self.subtitle
end

function Menu:updateItems(n, no_recalc)
    self.updated = (self.updated or 0) + 1
end

-- 如实模拟真实实现：直接访问 self.title_bar，若为 nil 就会抛错，
-- 这样「在 init 之前调用」这类 bug 才能在测试里暴露出来。
function Menu:setTitleBarLeftIcon(icon)
    self.title_bar:setLeftIcon(icon)
end

function Menu:onClose()
    self.closed = true
    UIManagerStub:close(self)
end

function Menu:onCloseWidget()
    self.closed_widget = true
end

function Menu:onMenuSelect(item)
    return true
end

function Menu:onMenuHold(item)
    return true
end

-- title_bar 的桩：同时记录以便断言
local TitleBarStub = {}
TitleBarStub.__index = TitleBarStub
function TitleBarStub:setLeftIcon(icon)
    if self.has_left_icon then
        self.left_icon = icon
    end
end
function TitleBarStub:setTitle(t) self.title = t end
function TitleBarStub:setSubTitle(t) self.subtitle = t end

SimpleTitleBarStub = { last_title = nil, last_subtitle = nil }

-- BookList：Menu 的子类，提供排序函数
local BookList = Menu:extend{
    collates = {},
}

-- 与 KOReader 一致：getCollateSortFunc 返回的是「比较函数本身」，
-- 而不是包着 sort_func 的 table。
local function textCompare(a, b)
    return (a.text or a.name or "") < (b.text or b.name or "")
end

local collate_funcs = {
    strcoll = function() return textCompare end,
    natural = function() return textCompare end,
    type = function() return textCompare end,
    size = function()
        return function(a, b) return (a.filesize or 0) < (b.filesize or 0) end
    end,
    date = function()
        return function(a, b) return (a.modification or 0) > (b.modification or 0) end
    end,
}

function BookList.getCollateSortFunc(collate)
    local init = collate_funcs[collate or "strcoll"] or collate_funcs.strcoll
    return init()
end

BookList.collates = {
    strcoll = { text = "name", init_sort_func = collate_funcs.strcoll },
    natural = { text = "name (natural)", init_sort_func = collate_funcs.natural },
    type = { text = "type", init_sort_func = collate_funcs.type },
}

function BookList.setBookInfoCache() end
function BookList.hasBookBeenOpened() return false end

--------------------------------------------------------------------------------
-- 假控件：只保存构造参数
--------------------------------------------------------------------------------

local function makeStubWidget(kind)
    local cls = Widget:extend{}
    function cls:init()
        self.kind = kind
        self.buttons = self.buttons or {}
    end
    function cls:getFields()
        local out = {}
        for _, f in ipairs(self.fields or {}) do
            out[#out + 1] = f.text or ""
        end
        return out
    end
    function cls:getInputText()
        return self.input or ""
    end
    function cls:onShowKeyboard() self.keyboard_shown = true end
    function cls:close() self.closed = true end
    function cls:setTitle(t) self.title = t end
    function cls:setSubTitle(t) self.subtitle = t end
    function cls:reportProgress(p) self.progress = p end
    function cls:onClose() self.closed = true end
    function cls:show() self.shown = true end
    function cls:setTitle(t) self.title = t end
    function cls:setSubTitle(t) self.subtitle = t end
    return cls
end

local ButtonDialog = makeStubWidget("ButtonDialog")
local ConfirmBox = makeStubWidget("ConfirmBox")
local InfoMessage = makeStubWidget("InfoMessage")
local InputDialog = makeStubWidget("InputDialog")
local MultiInputDialog = makeStubWidget("MultiInputDialog")
local ProgressbarDialog = makeStubWidget("ProgressbarDialog")
local Notification = makeStubWidget("Notification")

function Notification:new(o)
    local inst = Widget.new(self, o)
    inst.notified = true
    UIManagerStub.last_notification = inst
    return inst
end

--- 方便测试：从假控件里取出按钮（支持嵌套的按钮行）。
function UIStubs.getButtons(widget)
    return widget and widget.buttons or {}
end

--- 按文字找到按钮并调用它的 callback。
function UIStubs.clickButton(widget, text)
    local function scan(rows)
        for _, row in ipairs(rows or {}) do
            for _, btn in ipairs(row) do
                if btn and btn.text == text then
                    if btn.callback then btn.callback() end
                    return true
                end
            end
        end
        return false
    end
    return scan(widget and widget.buttons)
end

--------------------------------------------------------------------------------
-- 假 UI（FileManager / Reader 的替身）
--------------------------------------------------------------------------------

FakeUI = {}
FakeUI.__index = FakeUI

function FakeUI.new()
    local menu = {
        registerToMainMenu = function(self_menu, plugin)
            -- 调用插件的 addToMainMenu，模拟 KOReader 的行为
            local items = setmetatable({}, {
                __newindex = function(t, k, v)
                    rawset(t, k, v)
                    MenuRegistry.last_items[k] = v
                end,
            })
            if plugin.addToMainMenu then
                plugin:addToMainMenu(items)
            end
            plugin.registered_menu = true
        end,
    }
    local ui = setmetatable({
        menu = menu,
        doc_settings = nil,
        document = nil,
        file_chooser = nil,
        folder_shortcuts = {
            expandPath = function(_, p) return p end,
            registerShortcut = function() end,
            updateShortcut = function() end,
        },
        selected_files = nil,
    }, FakeUI)
    ui.openFile = function(self, file, provider, cb, aux, after)
        self.opened = file
    end
    return ui
end

--- 供 browser 用的插件替身。
FakePlugin = {}
FakePlugin.__index = FakePlugin

function FakePlugin.new()
    return setmetatable({
        open_calls = 0,
        download_calls = 0,
        opened_file = nil,
    }, FakePlugin)
end

function FakePlugin:getClientFor(server)
    local ok_p, plugin = pcall(function() return self end)
    return {
        download = function(_, remote_path, local_path, opts)
            self.download_calls = self.download_calls + 1
            local fh = io.open(local_path, "w")
            if fh then
                fh:write("downloaded content")
                fh:close()
            end
            return true, nil
        end,
    }
end

function FakePlugin:openRemoteFile(server, item, local_path)
    self.open_calls = self.open_calls + 1
    self.opened_file = local_path
    -- 模拟真实实现里登记 Session
    local Progress = require("wdr.progress")
    require("wdr.session").setCurrent(server, item.remote_path, local_path,
        Progress:getKey(server, item.remote_path))
end

--- 供 browser 用的 manager 替身。
FakeManager = {}
FakeManager.__index = FakeManager

function FakeManager.new(overrides)
    local base = {
        deleted = {},
        moved = {},
        created = {},
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return setmetatable(base, FakeManager)
end

function FakeManager:deleteFile(server, path)
    table.insert(self.deleted, path)
    return true
end

function FakeManager:deleteFolder(server, path)
    table.insert(self.deleted, path)
    return true, 1
end

function FakeManager:countFolderItems()
    return 2, 1
end

function FakeManager:moveItem(server, from, to)
    table.insert(self.moved, { from, to })
    return true
end

function FakeManager:renameFile(server, path, name)
    table.insert(self.moved, { path, name })
    return true, (path:match("^(.*)/") or "") .. name
end

function FakeManager:createFolder(server, parent, name)
    local p = parent == "" and name or (parent .. "/" .. name)
    table.insert(self.created, p)
    return true, p
end

function FakeManager:validateName(name)
    if not name or name == "" then return false, "Name is empty" end
    return true
end

--------------------------------------------------------------------------------
-- 安装
--------------------------------------------------------------------------------

function UIStubs.install()
    if UIStubs._installed then return UIStubs end

    UIManagerStub.reset()
    MenuRegistry.reset()
    ActionRegistry.reset()

    -- ui/widget/container/widgetcontainer
    package.preload["ui/widget/container/widgetcontainer"] = function()
        return Widget
    end

    -- ui/widget/menu 与 booklist
    package.preload["ui/widget/menu"] = function() return Menu end
    package.preload["ui/widget/booklist"] = function() return BookList end

    -- 各假控件
    package.preload["ui/widget/buttondialog"] = function() return ButtonDialog end
    package.preload["ui/widget/confirmbox"] = function() return ConfirmBox end
    package.preload["ui/widget/infomessage"] = function() return InfoMessage end
    package.preload["ui/widget/inputdialog"] = function() return InputDialog end
    package.preload["ui/widget/multiinputdialog"] = function() return MultiInputDialog end
    package.preload["ui/widget/progressbardialog"] = function() return ProgressbarDialog end
    package.preload["ui/widget/notification"] = function() return Notification end
    package.preload["ui/widget/pathchooser"] = function() return makeStubWidget("PathChooser") end
    package.preload["ui/widget/textviewer"] = function() return makeStubWidget("TextViewer") end
    package.preload["ui/widget/sortwidget"] = function() return makeStubWidget("SortWidget") end
    package.preload["ui/widget/buttonselector"] = function() return makeStubWidget("ButtonSelector") end
    package.preload["ui/widget/checkbutton"] = function() return makeStubWidget("CheckButton") end
    package.preload["ui/widget/multiconfirmbox"] = function() return makeStubWidget("MultiConfirmBox") end

    -- ui/uimanager
    package.preload["ui/uimanager"] = function()
        local UIManager = {}
        function UIManager:show(widget, refreshtype)
            table.insert(UIManagerStub.shown, widget)
            UIManagerStub.last_widget = widget
            if widget and widget.kind == "InfoMessage" then
                UIManagerStub.last_message = widget
            end
            if widget and widget.kind == "Notification" then
                UIManagerStub.last_notification = widget
            end
            return true
        end
        function UIManager:close(widget)
            table.insert(UIManagerStub.closed, widget)
            return true
        end
        -- 立即执行，避免测试需要驱动时钟
        function UIManager:scheduleIn(seconds, action, ...)
            table.insert(UIManagerStub.scheduled, { seconds = seconds })
            if action then action(...) end
        end
        function UIManager:nextTick(action, ...)
            if action then action(...) end
        end
        function UIManager:unschedule() end
        function UIManager:forceRePaint() end
        function UIManager:setDirty() end
        function UIManager:broadcastEvent() end
        return UIManager
    end

    -- ui/network/manager
    package.preload["ui/network/manager"] = function()
        local NetworkMgr = {}
        NetworkMgr.wifi_was_on = true
        function NetworkMgr:isOnline() return true end
        function NetworkMgr:willRerunWhenConnected(cb) return false end
        function NetworkMgr:runWhenOnline(cb) return cb() end
        return NetworkMgr
    end

    -- dispatcher
    package.preload["dispatcher"] = function()
        local Dispatcher = {}
        function Dispatcher:registerAction(name, spec)
            ActionRegistry.actions[name] = spec
        end
        function Dispatcher:addAction() end
        return Dispatcher
    end

    -- document/documentregistry
    package.preload["document/documentregistry"] = function()
        local DR = {}
        local supported = {
            txt = true, md = true, markdown = true, html = true, htm = true,
            epub = true, fb2 = true, mobi = true, azw3 = true, pdf = true,
            djvu = true, cbz = true, cbr = true, xps = true, chm = true,
            rtf = true, doc = true, docx = true, odt = true, png = true,
            jpg = true, jpeg = true, tif = true, tiff = true, gif = true, bmp = true,
        }
        function DR:hasProvider(file)
            local ext = tostring(file):match("%.([%w]+)$")
            return ext and supported[ext:lower()] == true
        end
        function DR:getProvider(file) return nil end
        return DR
    end

    -- ui/bidi
    package.preload["ui/bidi"] = function()
        local BD = {}
        function BD.dirpath(p) return p end
        function BD.filepath(p) return p end
        function BD.filename(p) return p end
        function BD.wrap(s) return s end
        return BD
    end

    -- apps/filemanager/filemanagerutil
    package.preload["apps/filemanager/filemanagerutil"] = function()
        local fu = {}
        function fu.openFile(ui, file, cb, no_dialog)
            ui.opened = file
        end
        function fu.abbreviate(p) return p end
        function fu.getHomeFolder() return "/home" end
        return fu
    end

    -- ui/widget/textview 等：若被间接引用则忽略
    UIStubs._installed = true
    return UIStubs
end

return UIStubs
