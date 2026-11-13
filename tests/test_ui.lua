-- @selfrun 自包含运行（内部 os.exit），由 run_all.lua 以子进程方式调用
--[[--
UI 层冒烟测试：用 KOReader 组件的轻量仿真验证 main.lua / browser.lua

桌面环境没有 KOReader 的完整 UI 栈（Widget、Input、Screen、Blitbuffer），
所以这里对 UI 组件做最小仿真，目标不是验证画面，而是验证：

  1. main.lua / browser.lua / _meta.lua 能被 require（无语法/依赖错误）
  2. 插件实例能 init，且注册了菜单与 dispatcher action
  3. browser 能根据假的 webdav client 构造出正确的 item_table
     （目录在前、进度标记、大小显示、远程路径正确）
  4. 打开文件的路径能走到 download 分支，并把上下文登记到 Session
  5. 进度能通过 onSaveSettings / onCloseDocument 回写到 JSON
  6. 关键的用户可见文案存在（防止误删）

@module tests.test_ui
--]]--

package.path = table.concat({
    "webdavreader.koplugin/?.lua",
    "tests/?.lua",
    package.path,
}, ";")
package.cpath = table.concat({
    "tools/?.so",
    package.cpath,
}, ";")

require("stubs").install()
require("ui_stubs").install()

-- ---------------------------------------------------------------------------
-- 极简断言
-- ---------------------------------------------------------------------------

local pass_count, fail_count = 0, 0
local failures = {}
local current_case = nil

local function ok(cond, msg)
    if cond then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] %s", current_case or "?", msg or "断言失败")
    end
    return cond
end

local function eq(actual, expected, msg)
    if actual == expected then
        pass_count = pass_count + 1
        return true
    end
    fail_count = fail_count + 1
    failures[#failures + 1] = string.format("[%s] %s\n      期望: %q\n      实际: %q",
        current_case or "?", msg or "值不相等", tostring(expected), tostring(actual))
    return false
end

local function contains(haystack, needle, msg)
    local cond = type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
    if not cond then
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] %s\n      期望包含: %q\n      实际: %q",
            current_case or "?", msg or "未包含", tostring(needle), tostring(haystack))
        return false
    end
    pass_count = pass_count + 1
    return true
end

local function case(name, fn)
    current_case = name
    UIManagerStub.reset()
    local okk, err = pcall(fn)
    if not okk then
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] 抛出异常: %s\n%s",
            name, tostring(err), debug.traceback("", 2))
    end
end

-- ---------------------------------------------------------------------------
-- 准备
-- ---------------------------------------------------------------------------

local test_data = "/tmp/wdr_ui_test_data"
os.execute("rm -rf '" .. test_data .. "'")
os.execute("mkdir -p '" .. test_data .. "/settings' '" .. test_data .. "/data'")
os.setenv = os.setenv or function() end
-- stubs 里的 datastorage 读环境变量，需要在 require 前设好（已在 stubs 里默认 /tmp/wdr_test_data）
os.execute("rm -rf /tmp/wdr_test_data && mkdir -p /tmp/wdr_test_data/settings /tmp/wdr_test_data/data")

local Config = require("wdr.config")
local Progress = require("wdr.progress")
local Cache = require("wdr.cache")
local Session = require("wdr.session")

--------------------------------------------------------------------------------
-- 用例 1：模块可加载
--------------------------------------------------------------------------------

case("_meta.lua 可加载且提供 fullname/description", function()
    local meta = dofile("webdavreader.koplugin/_meta.lua")
    ok(type(meta) == "table", "应返回 table")
    ok(meta.fullname and #meta.fullname > 0, "应有 fullname")
    ok(meta.description and #meta.description > 0, "应有 description")
end)

case("main.lua 可 require 且返回可 extend 的类", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    ok(type(Main) == "table", "应返回 table")
    ok(type(Main.new) == "function", "应有 new")
    ok(Main.name == "webdavreader", "插件名应为 webdavreader")
    eq(Main.is_doc_only, false, "应同时加载到 FileManager 与 Reader")
end)

case("browser.lua 可 require 且继承 menu 能力", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    ok(type(Browser) == "table", "应返回 table")
    ok(type(Browser.new) == "function", "应有 new")
    ok(type(Browser.onMenuSelect) == "function", "应实现 onMenuSelect")
    ok(type(Browser.onMenuHold) == "function", "应实现 onMenuHold")
    ok(type(Browser.enterPath) == "function", "应有 enterPath")
    ok(type(Browser.buildItemTable) == "function", "应有 buildItemTable")
end)

--------------------------------------------------------------------------------
-- 用例 2：插件实例化与菜单注册
--------------------------------------------------------------------------------

case("插件实例 init 后注册了主菜单与 dispatcher", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    ok(plugin, "应能实例化")
    ok(plugin.registered_menu, "应注册主菜单")
    ok(ActionRegistry.actions.webdavreader, "应注册 dispatcher action")
    ok(MenuRegistry.last_items.webdavreader, "主菜单应有 webdavreader 项")
    local item = MenuRegistry.last_items.webdavreader
    eq(item.text, "WebDAV 远程阅读", "菜单文字")
    ok(type(item.sub_item_table) == "table", "应有子菜单")
    eq(#item.sub_item_table, 5, "应有 5 个子项（浏览/服务器/缓存/进度/移动位置记录）")
end)

case("子菜单覆盖核心功能", function()
    local items = MenuRegistry.last_items.webdavreader.sub_item_table
    local texts = {}
    for _, it in ipairs(items) do texts[#texts + 1] = it.text end
    local joined = table.concat(texts, "|")
    contains(joined, "浏览远程文件", "应有浏览入口")
    contains(joined, "服务器设置", "应有服务器设置")
    contains(joined, "缓存设置", "应有缓存设置")
    contains(joined, "阅读进度记录", "应有进度查看")
    contains(joined, "移动位置记录", "应有移动位置记录入口")
end)

--------------------------------------------------------------------------------
-- 用例 3：浏览界面构造 item_table
--------------------------------------------------------------------------------

case("buildItemTable：目录在前、含进度标记与大小", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")

    -- 准备一台服务器与假 client
    Config:load()
    local idx = Config:addServer({
        name = "测试服务器",
        address = "http://example.test/dav",
        username = "u", password = "p",
    })
    local server = Config:getServer(idx)

    -- 写入一条进度
    Progress:init("/tmp/wdr_test_data/settings/progress.json")
    Progress:save(server, "books/a.txt", { percent = 0.42, page = 12 })

    local plugin = {
        config = Config,
        progress = Progress,
        cache = Cache,
        getClientFor = function(self, srv)
            return {
                list = function()
                    return {
                        { name = "sub", is_folder = true, path = "sub" },
                        { name = "a.txt", is_folder = false, path = "books/a.txt", size = 2048 },
                        { name = "b.md", is_folder = false, path = "books/b.md", size = 512 },
                    }
                end,
            }
        end,
    }

    local browser = Browser:new{
        plugin = plugin,
        config = Config,
        progress = Progress,
        cache = Cache,
        collate = "strcoll",
    }
    browser:init()
    browser.server_idx = idx
    browser.path = "books"

    local items = {
        { name = "sub", is_folder = true, path = "books/sub" },
        { name = "a.txt", is_folder = false, path = "books/a.txt", size = 2048 },
        { name = "b.md", is_folder = false, path = "books/b.md", size = 512 },
    }
    local tbl = browser:buildItemTable(items, "books")

    eq(#tbl, 3, "应有 3 项")
    eq(tbl[1].is_folder, true, "目录应排在第一")
    eq(tbl[1].name, "sub", "目录名")
    eq(tbl[1].remote_path, "books/sub", "目录远程路径")

    -- 文件按名字排序
    eq(tbl[2].name, "a.txt", "第一个文件")
    eq(tbl[3].name, "b.md", "第二个文件")

    -- a.txt 有进度，应显示 ★42%
    eq(tbl[2].is_file, true, "应是文件")
    contains(tbl[2].mandatory, "★", "有进度应带星标")
    contains(tbl[2].mandatory, "42%", "应显示百分比")
    contains(tbl[2].mandatory, "KB", "应显示大小")

    -- b.md 无进度
    ok(not tbl[3].mandatory:find("★", 1, true), "无进度不应带星标")
end)

case("buildItemTable 不因单个条目异常而崩溃", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local browser = Browser:new{
        plugin = { config = Config },
        config = Config,
        progress = Progress,
        cache = Cache,
    }
    browser:init()
    browser.server_idx = 1
    -- 缺 path 字段（依赖 fallback 拼接）
    local tbl = browser:buildItemTable({
        { name = "x.txt", is_folder = false, size = 10 },
    }, "dir")
    eq(#tbl, 1, "应能处理")
    eq(tbl[1].remote_path, "dir/x.txt", "应回退拼出远程路径")
end)

--------------------------------------------------------------------------------
-- 用例 4：打开远程文件
--------------------------------------------------------------------------------

case("回归 P0：Browser:init 不得在 title_bar 创建前调用 setTitleBarLeftIcon", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    -- 桩件里的 setTitleBarLeftIcon 会访问 self.title_bar，
    -- 若 init 里提前调用就会抛 "attempt to index a nil value"
    local okk, err = pcall(function()
        return Browser:new{
            plugin = FakePlugin.new(),
            config = Config,
            progress = Progress,
            cache = Cache,
            manager = FakeManager.new(),
            server_idx = 1,
            title_bar_left_icon = "plus",
        }
    end)
    ok(okk, "构造不应抛错：" .. tostring(err))
end)

case("回归 P1：dir_stack 不被 Menu:init 的 paths 重置影响", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local browser = Browser:new{
        plugin = FakePlugin.new(), config = Config,
        progress = Progress, cache = Cache, manager = FakeManager.new(),
        server_idx = 1,
    }
    -- Menu:init 会把 self.paths 置为 {}，我们的栈必须独立存活
    eq(#browser.dir_stack, 1, "dir_stack 应存在且有根元素")
    eq(#browser.paths, 0, "Menu 自己的 paths 被重置（说明我们没用它）")
    -- 模拟进入子目录
    browser.dir_stack[#browser.dir_stack + 1] = "books"
    ok(#browser.dir_stack > 1, "「返回上级」应可用（栈深度 > 1）")
end)

case("回归 P2：详情页在 cache 未设目录时不因 lfs.attributes(nil) 崩溃", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local Cache2 = require("wdr.cache")
    local saved_dir = Cache2.dir
    local browser = Browser:new{
        plugin = FakePlugin.new(), config = Config,
        progress = Progress, cache = Cache2, manager = FakeManager.new(),
        server_idx = 1,
    }
    Cache2:setDir(nil)  -- 模拟未初始化
    local okk, err = pcall(function()
        browser:showFileInfo({
            name = "x.txt", is_file = true,
            remote_path = "books/x.txt", filesize = 10,
        })
    end)
    Cache2:setDir(saved_dir)
    ok(okk, "详情页不应崩溃：" .. tostring(err))
end)

case("openFile：缓存新鲜时直接打开，不下载", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local plugin = FakePlugin.new()
    local browser = Browser:new{
        plugin = plugin,
        config = Config,
        progress = Progress,
        cache = Cache,
        manager = FakeManager.new(),
    }
    browser:init()
    browser.server_idx = 1
    browser.item_table = {}

    local server = Config:getServer(1)
    -- 造一个「新鲜」的本地缓存文件
    Cache:setDir("/tmp/wdr_test_data/data/webdavreader_cache")
    Cache:ensureDir()
    local local_path = Cache:getLocalPath(server, "books/fresh.txt")
    local fh = io.open(local_path, "w") fh:write("0123456789") fh:close()

    local item = {
        name = "fresh.txt", is_file = true,
        remote_path = "books/fresh.txt", filesize = 10,
    }
    browser:openFile(item)

    ok(plugin.opened_file, "应调用打开")
    eq(plugin.opened_file, local_path, "应打开缓存文件")
    eq(plugin.open_calls, 1, "只打开一次")
    eq(plugin.download_calls, 0, "新鲜缓存不应重新下载")
    ok(Session.current, "应登记当前远程上下文")
    eq(Session.current.remote_path, "books/fresh.txt", "远程路径正确")
end)

case("openFile：缓存缺失时走下载分支", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local plugin = FakePlugin.new()
    local browser = Browser:new{
        plugin = plugin,
        config = Config,
        progress = Progress,
        cache = Cache,
        manager = FakeManager.new(),
    }
    browser:init()
    browser.server_idx = 1
    browser.item_table = {}

    local item = {
        name = "new.txt", is_file = true,
        remote_path = "books/new.txt", filesize = 100,
    }
    browser:openFile(item)
    -- downloadAndOpen 用 scheduleIn 延迟执行，仿真里会立即执行
    eq(plugin.download_calls, 1, "应发起一次下载")
    ok(plugin.opened_file ~= nil, "下载后应打开")
end)

case("browser 构造后 server_idx 不被 init 重置（回归：重复 init 曾丢失状态）", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local browser = Browser:new{
        plugin = FakePlugin.new(),
        config = Config,
        progress = Progress,
        cache = Cache,
        manager = FakeManager.new(),
        server_idx = 2,
    }
    -- new() 内部已调用 init()；模拟 main.lua 传入的 server_idx 必须保留
    eq(browser.server_idx, 2, "构造参数应保留")
    browser:init()
    eq(browser.server_idx, 2, "即使再调 init 也不应清空 server_idx")
    ok(type(browser.dir_stack) == "table", "dir_stack 栈应被初始化")
    eq(#browser.dir_stack, 1, "初始栈只有一个根")
end)

case("openFile：不支持的格式给出提示而非崩溃", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local plugin = FakePlugin.new()
    local browser = Browser:new{
        plugin = plugin,
        config = Config,
        progress = Progress,
        cache = Cache,
        manager = FakeManager.new(),
    }
    browser:init()
    browser.server_idx = 1

    browser:openFile({
        name = "weird.xyz", is_file = true,
        remote_path = "books/weird.xyz", filesize = 10,
    })
    eq(plugin.open_calls, 0, "不应尝试打开")
    ok(UIManagerStub.last_message, "应给出提示")
    contains(UIManagerStub.last_message.text, "不支持", "提示应说明不支持")
end)

--------------------------------------------------------------------------------
-- 用例 5：进度回写
--------------------------------------------------------------------------------

case("onSaveSettings 把阅读进度写进插件 JSON", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local ui = FakeUI.new()
    local plugin = Main:new{ ui = ui }

    local server = Config:getServer(1)
    local local_path = "/tmp/wdr_test_data/data/webdavreader_cache/some.txt"
    Session.setCurrent(server, "books/progress.txt", local_path, Progress:getKey(server, "books/progress.txt"))

    -- 模拟 Reader 的 doc_settings
    ui.doc_settings = {
        data = {
            last_xpointer = "/body/DocFragment[5]/body/p[3]/text().0",
            percent_finished = 0.66,
            doc_pages = 120,
        },
        readSetting = function(self, k, d) local v = self.data[k] if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self.data[k] = v end,
    }
    ui.document = { file = local_path }

    plugin:onSaveSettings()

    local entry = Progress:get(server, "books/progress.txt")
    ok(entry, "应写入进度")
    eq(entry.percent, 0.66, "百分比")
    eq(entry.xpointer, "/body/DocFragment[5]/body/p[3]/text().0", "xpointer")
    eq(entry.total_pages, 120, "总页数")
end)

case("onDocSettingsLoad 从插件 JSON 恢复进度", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local ui = FakeUI.new()
    local plugin = Main:new{ ui = ui }

    local server = Config:getServer(1)
    local local_path = "/tmp/wdr_test_data/data/webdavreader_cache/restore.txt"
    Progress:save(server, "books/restore.txt", {
        percent = 0.77,
        xpointer = "/body/DocFragment[9]/body/p[1]/text().0",
        page = 88,
        updated = os.time(),
    })
    Session.setCurrent(server, "books/restore.txt", local_path, Progress:getKey(server, "books/restore.txt"))

    local doc_settings = {
        data = {},
        readSetting = function(self, k, d) local v = self.data[k] if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self.data[k] = v end,
    }
    plugin:onDocSettingsLoad(doc_settings, { file = local_path })

    eq(doc_settings.data.last_xpointer, "/body/DocFragment[9]/body/p[1]/text().0", "应恢复 xpointer")
    eq(doc_settings.data.last_page, 88, "应恢复页码")
    eq(doc_settings.data.percent_finished, 0.77, "应恢复百分比")
end)

case("onDocSettingsLoad 不覆盖更新的 sidecar 进度", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local ui = FakeUI.new()
    local plugin = Main:new{ ui = ui }

    local server = Config:getServer(1)
    local local_path = "/tmp/wdr_test_data/data/webdavreader_cache/conflict.txt"
    Progress:save(server, "books/conflict.txt", { percent = 0.10, updated = 1000 })
    Session.setCurrent(server, "books/conflict.txt", local_path, Progress:getKey(server, "books/conflict.txt"))

    -- sidecar 里进度更靠后（用户在别的入口读得更多）
    local doc_settings = {
        data = {
            percent_finished = 0.90,
            webdavreader_updated = 2000,
        },
        readSetting = function(self, k, d) local v = self.data[k] if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self.data[k] = v end,
    }
    plugin:onDocSettingsLoad(doc_settings, { file = local_path })

    eq(doc_settings.data.percent_finished, 0.90, "不应被更旧的记录覆盖")
end)

case("翻页节流：10 页内不写盘，满 10 页后触发快照", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local ui = FakeUI.new()
    local plugin = Main:new{ ui = ui }

    local server = Config:getServer(1)
    Progress:remove(server, "books/throttle.txt")
    local local_path = "/tmp/wdr_test_data/data/webdavreader_cache/throttle.txt"
    Session.setCurrent(server, "books/throttle.txt", local_path, Progress:getKey(server, "books/throttle.txt"))
    ui.doc_settings = {
        data = { percent_finished = 0.3, last_page = 3 },
        readSetting = function(self, k, d) local v = self.data[k] if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self.data[k] = v end,
    }
    ui.document = { file = local_path }

    -- 前 9 页不应写盘
    for i = 1, 9 do plugin:onPageUpdate(i) end
    eq(Progress:get(server, "books/throttle.txt"), nil, "未满 10 页不应写盘")

    -- 第 10 页应触发（仿真里 scheduleIn 会立即执行）
    plugin:onPageUpdate(10)
    local entry = Progress:get(server, "books/throttle.txt")
    ok(entry, "满 10 页应写入进度")
    eq(entry.percent, 0.3, "应写入当前进度")
end)

case("滚动模式 PosUpdate 按时间节流，不会每次调用都写盘", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local ui = FakeUI.new()
    local plugin = Main:new{ ui = ui }

    local server = Config:getServer(1)
    local local_path = "/tmp/wdr_test_data/data/webdavreader_cache/scroll.txt"
    Session.setCurrent(server, "books/scroll.txt", local_path, Progress:getKey(server, "books/scroll.txt"))
    ui.doc_settings = {
        data = { percent_finished = 0.4 },
        readSetting = function(self, k, d) local v = self.data[k] if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self.data[k] = v end,
    }
    ui.document = { file = local_path }

    Progress:remove(server, "books/scroll.txt")
    -- 第一次会触发
    plugin:onPosUpdate(100, 1)
    ok(Progress:get(server, "books/scroll.txt"), "首次应写盘")

    -- 紧接着大量调用，应被时间节流挡住（不会反复写盘）
    local before = Progress:get(server, "books/scroll.txt").updated
    for i = 1, 100 do plugin:onPosUpdate(i * 10, i) end
    local after = Progress:get(server, "books/scroll.txt").updated
    eq(after, before, "短时间内的密集更新不应重复写盘")
end)

case("onCloseDocument 保存进度并清理会话", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local ui = FakeUI.new()
    local plugin = Main:new{ ui = ui }

    local server = Config:getServer(1)
    local local_path = "/tmp/wdr_test_data/data/webdavreader_cache/close.txt"
    Session.setCurrent(server, "books/close.txt", local_path, Progress:getKey(server, "books/close.txt"))
    ui.doc_settings = {
        data = { percent_finished = 0.55, last_page = 5 },
        readSetting = function(self, k, d) local v = self.data[k] if v == nil then return d end return v end,
        saveSetting = function(self, k, v) self.data[k] = v end,
    }
    ui.document = { file = local_path }

    plugin:onCloseDocument()
    eq(Session.current, nil, "应清理当前会话")
    local entry = Progress:get(server, "books/close.txt")
    ok(entry, "关闭时应保存进度")
    eq(entry.percent, 0.55, "百分比应保存")
end)

--------------------------------------------------------------------------------
-- 用例 6：配置/缓存界面的关键文案
--------------------------------------------------------------------------------

case("缓存清理文案说明不影响进度与远程文件", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    plugin:showCacheDialog()
    ok(UIManagerStub.last_widget, "应弹出缓存对话框")
    local titles = UIManagerStub.collect_texts(UIManagerStub.last_widget)
    local all = table.concat(titles, "\n")
    contains(all, "缓存", "应提到缓存")
    contains(all, "上限", "应有上限设置")
    contains(all, "清理", "应有清理按钮")
end)

case("删除服务器前提示会清理进度", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    plugin:showServerMenu(1)
    local texts = table.concat(UIManagerStub.collect_texts(UIManagerStub.last_widget), "\n")
    contains(texts, "删除服务器", "应有删除服务器")
    contains(texts, "清空进度", "应有清空进度")
    contains(texts, "编辑", "应有编辑")
end)

--------------------------------------------------------------------------------
-- 用例 7：排序选项（wdr/sort.lua 与 browser 的接线）
--------------------------------------------------------------------------------

local Sort = require("wdr.sort")
local History = require("wdr.history")
local UI = require("ui_stubs")

local TEST_SERVER_SEQ = 0

--- 新建一台隔离的测试服务器（地址各不相同，避免与进度/历史互相干扰）。
-- @return number idx, table server
local function addTestServer(prefix)
    TEST_SERVER_SEQ = TEST_SERVER_SEQ + 1
    local idx = Config:addServer({
        name = (prefix or "测试排序") .. TEST_SERVER_SEQ,
        address = "http://ui" .. TEST_SERVER_SEQ .. ".example.test/dav",
        username = "u",
        password = "p",
    })
    return idx, Config:getServer(idx)
end

--- 构造一个带假 client 的 browser（每个用例各自独立，避免状态串味）。
-- @param opts table { items=, manager=, path=, on_sort_changed= }
-- @return table browser, number idx, table server
local function newTestBrowser(opts)
    opts = opts or {}
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local idx, server = addTestServer()
    local plugin = FakePlugin.new()
    if opts.items then
        plugin.getClientFor = function()
            return { list = function() return opts.items end }
        end
    end
    local browser = Browser:new{
        plugin = plugin,
        config = Config,
        progress = Progress,
        cache = Cache,
        manager = opts.manager or FakeManager.new(),
        server_idx = idx,
        -- 与 main.lua 的 openBrowserFor 保持一致：左按钮靠构造参数声明
        title_bar_left_icon = "appbar.menu",
    }
    if opts.path ~= nil then
        browser.path = opts.path
    end
    -- 显式置一次默认排序状态，保证每个用例起点一致（默认值不触发回调）
    browser:setSort("name", false, true)
    if opts.on_sort_changed then
        browser.on_sort_changed = opts.on_sort_changed
    end
    return browser, idx, server
end

--- 排序夹具：modified 与 created 的顺序刻意相反（验证「只按 created 排」）。
local function sortFixture()
    return {
        { name = "sub", is_folder = true, path = "books/sub" },
        { name = "a.txt", is_folder = false, path = "books/a.txt", size = 300,
          modified = 1000, created = 4000 },
        { name = "b.txt", is_folder = false, path = "books/b.txt", size = 100,
          modified = 4000, created = 1000 },
        { name = "a10.txt", is_folder = false, path = "books/a10.txt", size = 200,
          modified = 2000, created = 2000 },
        { name = "a2.txt", is_folder = false, path = "books/a2.txt", size = 400,
          modified = 3000, created = 3000 },
    }
end

local function namesOf(tbl)
    local out = {}
    for _, it in ipairs(tbl or {}) do out[#out + 1] = it.name end
    return table.concat(out, ",")
end

local function indexOfName(tbl, name)
    for i, it in ipairs(tbl or {}) do
        if it.name == name then return i end
    end
    return nil
end

local function findItem(tbl, name)
    for _, it in ipairs(tbl or {}) do
        if it.name == name then return it end
    end
    return nil
end

--- 按文案取按钮（比按下标取更精确，不受按钮行顺序影响）。
local function buttonByText(dialog, text)
    for _, row in ipairs((dialog and dialog.buttons) or {}) do
        for _, btn in ipairs(row) do
            if btn and btn.text == text then return btn end
        end
    end
    return nil
end

case("排序：默认按名称升序、目录优先", function()
    local browser = newTestBrowser()
    eq(browser.sort_key, "name", "默认排序键应为 name")
    eq(browser.sort_descending, false, "默认应为升序")
    eq(browser.sort_folders_first, true, "默认应目录优先")
    eq(Sort.DEFAULT_KEY, "name", "Sort.DEFAULT_KEY 应为 name")
    eq(#Sort.keys, 6, "应有 6 种排序方式")

    local items = sortFixture()
    browser.raw_items = items
    browser:buildItemTable(items, "books")
    eq(#browser.item_table, 5, "应有 5 项")
    eq(browser.item_table[1].is_folder, true, "目录应排第一")
    eq(namesOf(browser.item_table), "sub,a.txt,a10.txt,a2.txt,b.txt", "按名称升序")

    local opts = browser:getSortOptions()
    eq(opts.key, "name", "getSortOptions.key")
    eq(opts.descending, false, "getSortOptions.descending")
    eq(opts.folders_first, true, "getSortOptions.folders_first")
end)

case("排序：大小升序 / 降序", function()
    local browser = newTestBrowser()
    local items = sortFixture()
    browser.raw_items = items
    browser:setSort("size", false, true)
    eq(namesOf(browser.item_table), "sub,b.txt,a10.txt,a.txt,a2.txt", "size 升序")
    eq(browser.item_table[2].name, "b.txt", "最小的文件在最前")
    browser:setSort("size", true, true)
    eq(browser.sort_key, "size", "排序键应切到 size")
    eq(browser.sort_descending, true, "方向应为降序")
    eq(namesOf(browser.item_table), "sub,a2.txt,a.txt,a10.txt,b.txt", "size 降序")
    eq(browser.item_table[1].is_folder, true, "降序时目录仍优先")
end)

case("排序：修改时间 / 创建时间各自独立（created 只看 created）", function()
    local browser = newTestBrowser()
    local items = sortFixture()
    browser.raw_items = items
    browser:setSort("modified", true, true)
    eq(namesOf(browser.item_table), "sub,b.txt,a2.txt,a10.txt,a.txt", "修改时间新的在前")
    browser:setSort("created", true, true)
    eq(namesOf(browser.item_table), "sub,a.txt,a2.txt,a10.txt,b.txt",
        "创建时间新的在前（与 modified 顺序相反，说明只用了 created）")
    eq(browser.item_table[2].name, "a.txt", "created 最新的是 a.txt")
end)

case("排序：自然排序让 a2.txt 排在 a10.txt 前面", function()
    local browser = newTestBrowser()
    browser.raw_items = sortFixture()
    browser:setSort("name_natural", false, true)
    local i2 = indexOfName(browser.item_table, "a2.txt")
    local i10 = indexOfName(browser.item_table, "a10.txt")
    ok(i2 and i10, "两个文件都应存在")
    ok(i2 < i10, "自然排序：a2.txt 应排在 a10.txt 前")
    browser:setSort("name", false, true)
    ok(indexOfName(browser.item_table, "a10.txt") < indexOfName(browser.item_table, "a2.txt"),
        "普通名称排序：a10.txt 在 a2.txt 前（字节序）")
end)

case("排序：folders_first=false 时目录与文件混排", function()
    local browser = newTestBrowser()
    browser.raw_items = sortFixture()
    browser:setSort("name", false, false)
    eq(browser.sort_folders_first, false, "目录优先应被关闭")
    eq(namesOf(browser.item_table), "a.txt,a10.txt,a2.txt,b.txt,sub", "目录按名称混入文件之间")
    ok(browser.item_table[1].is_folder ~= true, "目录不应排在第一位")
    eq(browser.item_table[5].name, "sub", "目录 sub 应排在最后")
end)

case("排序：on_sort_changed 只在真的变化时回调", function()
    local calls = {}
    local browser = newTestBrowser{
        on_sort_changed = function(key, descending, folders_first)
            calls[#calls + 1] = { key, descending, folders_first }
        end,
    }
    eq(#calls, 0, "构造后不应触发回调")
    browser:setSort("size", false, true)
    eq(#calls, 1, "排序变化应回调一次")
    eq(calls[1][1], "size", "回调应带上新排序键")
    eq(calls[1][2], false, "回调应带上方向")
    eq(calls[1][3], true, "回调应带上目录优先")
    browser:setSort("size", false, true)
    eq(#calls, 1, "值未变时不应重复回调")
    browser:setSort("size", true, true)
    eq(#calls, 2, "方向变化应回调")
    eq(calls[2][2], true, "回调应带上新方向")
    browser:setSort("size", true, false)
    eq(#calls, 3, "目录优先变化也算变化")
    eq(calls[3][3], false, "回调应带上新的目录优先值")
end)

case("排序：非法键回退默认值且不抛错", function()
    local browser = newTestBrowser()
    local okk, err = pcall(function() browser:setSort("bogus", false, true) end)
    ok(okk, "setSort 非法键不应抛错：" .. tostring(err))
    eq(browser.sort_key, "name", "非法键应回退 name")
    eq(Sort.resolve("bogus"), "name", "Sort.resolve 非法键回退")
    eq(Sort.resolve(nil), "name", "Sort.resolve(nil) 回退")
    eq(Sort.resolve(123), "name", "Sort.resolve 非字符串回退")
    eq(browser:getSortSummary(), "名称 ↑", "摘要应回到名称升序")
end)

case("排序：日期键在 mandatory 里显示日期，名称键不显示", function()
    local browser = newTestBrowser()
    browser.raw_items = sortFixture()
    browser:setSort("modified", true, true)
    local a = findItem(browser.item_table, "a.txt")
    ok(a and a.mandatory, "应有文件项与 mandatory")
    contains(a.mandatory, os.date("%Y-%m-%d", 1000), "修改时间键应显示 modified 日期")
    eq(Sort.KEY_BY_ID.modified.date_based, true, "modified 是日期类")
    eq(Sort.KEY_BY_ID.modified.descending, true, "时间类内建方向为新→旧")

    browser:setSort("name", false, true)
    local b = findItem(browser.item_table, "a.txt")
    ok(b, "应有文件项")
    ok(b.mandatory:find("%d%d%d%d%-%d%d%-%d%d") == nil, "名称排序不应显示日期")
    contains(b.mandatory, "B", "仍应显示大小")

    browser:setSort("created", true, true)
    local c = findItem(browser.item_table, "a.txt")
    contains(c.mandatory, os.date("%Y-%m-%d", 4000), "创建时间键应显示 created 日期")
end)

case("排序：副标题包含路径与排序摘要", function()
    local browser = newTestBrowser{ path = "books" }
    browser:setSort("size", false, true)
    local subtitle = browser:getSubtitle()
    contains(subtitle, "/books", "副标题应含当前路径")
    contains(subtitle, "大小", "副标题应含排序方式")
    contains(subtitle, "↑", "升序用 ↑")
    eq(browser:getSortSummary(), "大小 ↑", "摘要文案")
    browser:setSort("size", true, true)
    contains(browser:getSortSummary(), "↓", "降序用 ↓")
    eq(browser:getSortSummary(), "大小 ↓", "降序摘要文案")
    contains(browser:getSubtitle(), "/books", "切换方向后路径仍在")
end)

case("排序：进入目录后排序状态保持（enterPath 复用实例）", function()
    local browser = newTestBrowser{ items = sortFixture() }
    browser:setSort("size", true, true)
    browser:enterPath("books")
    eq(browser.path, "books", "应进入 books")
    eq(browser.sort_key, "size", "进入目录不应重置排序键")
    eq(browser.sort_descending, true, "进入目录不应重置方向")
    eq(browser.sort_folders_first, true, "进入目录不应重置目录优先")
    eq(namesOf(browser.item_table), "sub,a2.txt,a.txt,a10.txt,b.txt", "新目录仍按大小降序")
    eq(SimpleTitleBarStub.last_subtitle, browser:getSubtitle(), "标题栏副标题应同步")
    contains(SimpleTitleBarStub.last_subtitle, "大小", "副标题含排序方式")
end)

case("排序对话框：当前项打勾、未选中项显示内建方向", function()
    local browser = newTestBrowser()
    -- Menu:init 必须真的创建左按钮，否则真机上目录菜单（含排序）根本打不开
    eq(browser.title_bar.has_left_icon, true, "应创建左上角按钮")
    -- 目录菜单里的排序摘要要靠模板渲染（"排序：%1" -> "排序：名称 ↑"）
    browser:showFolderMenu()
    ok(UIManagerStub.find_text(UIManagerStub.last_widget, "排序：名称 ↑"),
        "目录菜单应显示渲染后的排序摘要（模板参数必须被替换）")

    browser:showSortDialog()
    local dialog = UIManagerStub.last_widget
    eq(dialog.kind, "ButtonDialog", "排序对话框应是按钮弹窗")
    eq(dialog.title, "排序方式", "标题")
    ok(UIManagerStub.find_text(dialog, "✓ 名称"), "当前项（名称）应有勾")
    ok(UIManagerStub.find_text(dialog, "修改时间 ↓"), "时间类未选中时显示内建方向")
    ok(not UIManagerStub.find_text(dialog, "✓ 修改时间"), "非当前项不应有勾")
    ok(UIManagerStub.find_text(dialog, "目录优先：开"), "应有目录优先开关")
end)

case("排序对话框：目录优先按钮翻转 sort_folders_first", function()
    local browser = newTestBrowser()
    browser:showSortDialog()
    ok(UI.clickButton(UIManagerStub.last_widget, "✓ 目录优先：开"), "应能点到目录优先按钮")
    eq(browser.sort_folders_first, false, "点击后应变为关闭")
    browser:showSortDialog()
    ok(UIManagerStub.find_text(UIManagerStub.last_widget, "目录优先：关"), "关闭后文案应变化")
    ok(UI.clickButton(UIManagerStub.last_widget, "目录优先：关"), "应能再次点击")
    eq(browser.sort_folders_first, true, "再次点击应恢复开启")
end)

--------------------------------------------------------------------------------
-- 用例 8：移动位置历史（browser 的快捷移动 + main 的记录查看）
--------------------------------------------------------------------------------

local HISTORY_SEQ = 0

--- 每个用例用一份独立的历史 JSON，避免互相污染。
-- 先删掉同名文件：同一序号在多次运行之间会重复出现，
-- 若上次运行留下了记录（例如进程被中断没走到末尾的清理），
-- 这里就会读到陈旧历史，导致「无历史」这类用例偶发失败。
local function freshHistoryStore()
    HISTORY_SEQ = HISTORY_SEQ + 1
    local path = "/tmp/wdr_ui_test_data/history_" .. HISTORY_SEQ .. ".json"
    os.remove(path)
    History:init(path)
    eq(#History:list({ address = "http://hermetic-check.invalid/dav" }), 0,
        "历史存储应是空的（用例之间互不影响）")
    return path
end

case("移动对话框：历史目标出现在按钮里", function()
    freshHistoryStore()
    local browser, _, server = newTestBrowser()
    eq(History:add(server, "books/done"), true, "应能写入一条历史")
    browser:showMoveDialog({ name = "x.txt", is_file = true, remote_path = "books/x.txt" })
    local dialog = UIManagerStub.last_widget
    eq(dialog.kind, "ButtonDialog", "移动对话框应是按钮弹窗")
    contains(dialog.title, "移动到", "标题应说明移动")
    contains(dialog.title, "x.txt", "标题应含文件名")
    ok(UIManagerStub.find_text(dialog, "/books/done"), "历史目标应出现在按钮里")
    ok(UIManagerStub.find_text(dialog, "其他位置"), "应保留手输入口")
    eq(browser.MOVE_HISTORY_LIMIT, 8, "界面最多显示 8 条历史")
end)

case("移动对话框：不显示当前所在目录", function()
    freshHistoryStore()
    local browser, _, server = newTestBrowser()
    History:add(server, "books")    -- 当前目录
    History:add(server, "papers")
    browser:showMoveDialog({ name = "x.txt", is_file = true, remote_path = "books/x.txt" })
    local dialog = UIManagerStub.last_widget
    ok(UIManagerStub.find_text(dialog, "/papers"), "其他历史目录应显示")
    ok(not UIManagerStub.find_text(dialog, "/books"), "当前目录不应出现在快捷项里")
end)

case("移动对话框：无历史时显示占位项且不可点", function()
    freshHistoryStore()
    local browser = newTestBrowser()
    browser:showMoveDialog({ name = "x.txt", is_file = true, remote_path = "books/x.txt" })
    local dialog = UIManagerStub.last_widget
    ok(UIManagerStub.find_text(dialog, "（暂无历史位置）"), "应提示暂无历史")
    local btn = buttonByText(dialog, "（暂无历史位置）")
    ok(btn, "应有占位按钮")
    eq(btn.enabled, false, "占位按钮应禁用")
    ok(btn.callback == nil, "占位按钮不应有回调")
    -- 「其他位置…」始终可用，不能因为没历史就断掉手输路径
    local other = buttonByText(dialog, "其他位置…")
    ok(other, "应保留「其他位置…」")
    eq(type(other.callback), "function", "「其他位置…」应可点")
end)

case("移动对话框：点历史按钮 → 成功移动并写入历史", function()
    freshHistoryStore()
    local browser, _, server = newTestBrowser{ items = {} }
    History:add(server, "papers")
    browser:showMoveDialog({ name = "x.txt", is_file = true, remote_path = "books/x.txt" })
    ok(UI.clickButton(UIManagerStub.last_widget, "/papers"), "应能点到历史按钮")
    local list = History:list(server)
    eq(#list, 1, "历史仍只有一条（同目录累加而非新增）")
    eq(list[1].dir, "papers", "历史目录")
    eq(list[1].count, 2, "成功移动后次数应累加")
    eq(#browser.manager.moved, 1, "应调用一次 moveItem")
    eq(browser.manager.moved[1][1], "books/x.txt", "moveItem 源路径")
    eq(browser.manager.moved[1][2], "papers/x.txt", "moveItem 目标路径")
end)

case("移动失败：不写历史，只提示错误", function()
    freshHistoryStore()
    local browser, _, server = newTestBrowser{
        manager = FakeManager.new{ fail_move = true },
        items = {},
    }
    History:add(server, "papers")
    local before = History:list(server)
    browser:showMoveDialog({ name = "x.txt", is_file = true, remote_path = "books/x.txt" })
    ok(UI.clickButton(UIManagerStub.last_widget, "/papers"), "应能点到历史按钮")
    local after = History:list(server)
    eq(#after, #before, "失败不应新增历史")
    eq(after[1].count, 1, "失败不应累加次数")
    ok(UIManagerStub.last_message, "应提示失败")
    contains(UIManagerStub.last_message.text, "移动失败", "提示应说明移动失败")
    eq(#browser.manager.moved, 1, "仍应尝试一次移动")
end)

case("移动对话框：「其他位置…」弹出输入对话框", function()
    freshHistoryStore()
    local browser = newTestBrowser{ items = {} }
    browser:showMoveDialog({ name = "x.txt", is_file = true, remote_path = "books/x.txt" })
    ok(UI.clickButton(UIManagerStub.last_widget, "其他位置…"), "应能点到「其他位置…」")
    local dialog = UIManagerStub.last_widget
    eq(dialog.kind, "InputDialog", "应弹出输入对话框")
    contains(dialog.title, "移动到", "标题应说明移动")
    contains(dialog.description, "目标目录", "应说明填写含义")
    contains(dialog.description, "books/x.txt", "应提示当前路径（模板参数必须被替换）")
    eq(dialog.input, "books", "输入框应预填当前目录")
end)

case("移动对话框：最多列出 MOVE_HISTORY_LIMIT 条", function()
    freshHistoryStore()
    local browser, _, server = newTestBrowser()
    for i = 1, 10 do
        History:add(server, string.format("dir%02d", i))
    end
    browser:showMoveDialog({ name = "x.txt", is_file = true, remote_path = "books/x.txt" })
    local dialog = UIManagerStub.last_widget
    ok(UIManagerStub.find_text(dialog, "/dir10"), "最近用的应显示")
    ok(not UIManagerStub.find_text(dialog, "/dir01"), "超出上限的最旧记录不应显示")
    local rows = 0
    for _, row in ipairs(dialog.buttons) do
        if #row > 0 then rows = rows + 1 end
    end
    eq(rows, 9, "8 条历史 + 1 个「其他位置…」")
end)

case("main.showMoveHistory：有记录时按服务器分组列出", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    freshHistoryStore()
    local server = Config:getServer(1)
    eq(History:add(server, "books/done"), true, "应能写入历史")
    plugin:showMoveHistory()
    local dialog = UIManagerStub.last_widget
    eq(dialog.kind, "ButtonDialog", "应弹出按钮弹窗")
    contains(dialog.title, "移动位置记录", "标题应说明这是移动位置记录")
    contains(dialog.title, "（1 条）", "标题应带条数（模板参数必须被替换）")
    ok(UIManagerStub.find_text(dialog, "/books/done"), "应列出历史目录")
    ok(UIManagerStub.find_text(dialog, "清空全部移动记录"), "应提供清空入口")
end)

case("main.showMoveHistory：无记录时给提示", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    freshHistoryStore()
    plugin:showMoveHistory()
    ok(UIManagerStub.last_message, "应弹出提示")
    eq(UIManagerStub.last_widget.kind, "InfoMessage", "应使用 InfoMessage 而不是弹窗按钮")
    contains(UIManagerStub.last_message.text, "还没有移动记录", "提示应说明没有记录")
end)

case("main.openBrowserFor：恢复上次的排序偏好并回写", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    plugin.getClientFor = function()
        return {
            list = function()
                return { { name = "a.txt", is_folder = false, path = "books/a.txt", size = 10 } }
            end,
        }
    end
    local idx = Config:addServer({
        name = "恢复排序服务器",
        address = "http://restore-sort.example.test/dav",
        username = "u",
        password = "p",
        start_dir = "/books",
    })
    plugin:saveSortSettings("size", true, false)
    eq(plugin:readSetting("sort_key"), "size", "状态文件应已写入排序键")
    eq(plugin:readSetting("sort_descending"), true, "状态文件应已写入方向")
    eq(plugin:readSetting("sort_folders_first"), false, "状态文件应已写入目录优先")

    plugin:openBrowserFor(idx)
    local browser = plugin.browser
    ok(browser, "应创建 browser")
    eq(browser.sort_key, "size", "应恢复排序键")
    eq(browser.sort_descending, true, "应恢复方向")
    eq(browser.sort_folders_first, false, "应恢复目录优先")
    contains(browser:getSortSummary(), "大小", "副标题应显示恢复后的排序方式")
    contains(browser:getSortSummary(), "↓", "降序箭头")
    eq(type(browser.on_sort_changed), "function", "应接好回写状态的回调")
    -- 左上角按钮（目录菜单入口）必须真的存在，否则真机上打不开排序设置
    eq(browser.title_bar.has_left_icon, true, "openBrowserFor 应声明左按钮")
    eq(browser.title_bar.left_icon, "appbar.menu", "左按钮应是汉堡菜单图标")

    -- 之后再切排序：应通过回调写回插件状态文件
    browser:setSort("created", true, true)
    eq(plugin:readSetting("sort_key"), "created", "切换排序应写回状态")
    eq(plugin:readSetting("sort_folders_first"), true, "目录优先也应写回")
end)

-- ---------------------------------------------------------------------------
-- 用例 9：返回上一级（回归：左下角箭头永远不可点 + 置顶「⬆ ../」行）
--
-- 用户报障：「在打开的目录中不知道怎么返回；左下角的图标如果是返回上一层，
-- 之前的版本按下没有用。」背后是两个真 bug：
--
--   Bug 1（核心）：KOReader Menu:updatePageInfo 里有
--       self.page_return_arrow:enableDisable(#self.paths > 0)
--     即左下角返回箭头可点与否完全由 Menu 自己的 self.paths 决定；而本插件
--     从来不用 self.paths 做导航（Menu:init 会把它重置为 {}，插件用独立的
--     dir_stack），所以它永远空 → 箭头永远 disabled → 点下去毫无反应。
--     修法：Browser:syncMenuPaths() 把 dir_stack 的「可返回性」同步给 paths，
--     且回根时必须清空（只 insert 不清理 = 回根后箭头仍可点，也是 bug）。
--
--   Bug 2：用户不知道能返回。修法：子目录列表置顶一行 is_go_up 的「⬆ ../」，
--     由 wdr/sort.lua 保证它恒在最前（不受排序键/方向/目录优先影响）；
--     点击 → onReturn，长按 → 不弹无意义的文件管理菜单。
--
-- 下面这些用例就是钉死这两条修法：谁把 syncMenuPaths 的清理分支、enterPath 里
-- 的调用时机、或 sort.lua 的 is_go_up 短路删掉，这里都会变红。
-- ---------------------------------------------------------------------------

local BDStub = require("ui/bidi")

--- 数一列表里有几行「返回上一级」（正常应恰好 0 或 1 行，重复即为回归）。
local function countGoUp(tbl)
    local n = 0
    for _, it in ipairs(tbl or {}) do
        if it and it.is_go_up then n = n + 1 end
    end
    return n
end

--- 造一个「已经处在某个目录里」的 browser。
-- 等价于 onMenuSelect 点进目录后的状态（先压栈、再 enterPath）。
-- 刻意不靠点击目录项来进目录：那会走下载分支，而假 client 没有 download。
-- @param stack table 目录栈，如 { "", "books" }
-- @param items table|nil 服务器返回条目，缺省用 sortFixture()
local function browserInDir(stack, items)
    local browser = newTestBrowser{ items = items or sortFixture() }
    browser.dir_stack = stack
    browser:enterPath(stack[#stack])
    return browser
end

case("返回上一级（Bug1）：根目录时 paths 为空 → 左下角箭头禁用", function()
    local browser = browserInDir({ "" })
    eq(#browser.dir_stack, 1, "根目录栈深应为 1")
    eq(#browser.paths, 0, "根目录时 Menu.paths 必须为空（否则箭头可点但点了没反应）")
    eq(browser.paths[1], nil, "paths 不应残留任何占位元素")
    -- Bug 2 的另一半：根目录没有可上的级，就不该有「../」行
    ok(browser.item_table[1].is_go_up ~= true, "根目录首行不应是「../」")
    eq(countGoUp(browser.item_table), 0, "根目录不应出现任何「../」行")
    eq(#browser.item_table, #sortFixture(), "根目录只列真实条目（不多出导航行）")
end)

case("返回上一级（Bug1）：进入子目录后 paths 非空 → 箭头可点", function()
    local browser = browserInDir({ "", "books" })
    eq(#browser.dir_stack, 2, "进入子目录后栈深应为 2")
    eq(#browser.paths, 1, "子目录里 paths 应有一个占位元素 → Menu 会启用返回箭头")
    eq(browser.paths[1], true, "占位元素是 true（与官方 filemanagercollection 同款手法）")
    eq(browser.path, "books", "当前路径应是子目录")
    ok(#browser.paths > 0, "箭头可点的判据是 #paths > 0")
end)

case("返回上一级（Bug1）：回到根目录后 paths 必须被清空（清理分支回归）", function()
    local browser = browserInDir({ "", "books" })
    eq(#browser.paths, 1, "前置条件：子目录里箭头可点")

    browser:onReturn()

    eq(#browser.dir_stack, 1, "回根后栈深应回到 1")
    eq(#browser.paths, 0, "回根后 paths 必须清空，否则箭头仍显示可点（点下去没反应）")
    eq(browser.paths[1], nil, "清空是清空，不是留个 nil 洞")
    eq(browser.path, "", "当前路径应回到根")
    eq(countGoUp(browser.item_table), 0, "回根后「../」行应消失")

    -- 再进一次：paths 必须能重新长出来（只清不置 = 箭头又永远禁用）
    browser.dir_stack = { "", "books" }
    browser:enterPath("books")
    eq(#browser.paths, 1, "再次进子目录，箭头应重新可点")
end)

case("返回上一级（Bug1）：syncMenuPaths 幂等，连续调用不会让 paths 增长", function()
    local browser = browserInDir({ "" })
    eq(#browser.paths, 0, "前置：根目录 paths 为空")
    for _ = 1, 5 do browser:syncMenuPaths() end
    eq(#browser.paths, 0, "根目录上重复同步仍应是空表")

    browser.dir_stack = { "", "books" }
    for _ = 1, 5 do browser:syncMenuPaths() end
    eq(#browser.paths, 1, "子目录里重复同步只有 1 个元素（不是每次 insert 一个新元素）")
    eq(browser.paths[1], true, "重复同步不应破坏占位元素")

    browser.dir_stack = { "" }
    browser:syncMenuPaths()
    eq(#browser.paths, 0, "从子目录直接回根也会被清理（不只 onReturn 那条路）")
end)

case("返回上一级（Bug1）：同步时机必须在 switchItemTable 之前", function()
    -- switchItemTable → updateItems → updatePageInfo 会读 #self.paths，
    -- 所以必须在那之前同步；这里用个探针在 switchItemTable 被调用的瞬间取样。
    local browser = newTestBrowser{ items = sortFixture() }
    local seen = {}
    local original_switch = browser.switchItemTable
    browser.switchItemTable = function(self, ...)
        seen[#seen + 1] = #self.paths
        return original_switch(self, ...)
    end

    browser.dir_stack = { "" }
    browser:enterPath("")
    eq(seen[1], 0, "回根时 switchItemTable 之前 paths 已是空（箭头禁用）")

    browser.dir_stack = { "", "books" }
    browser:enterPath("books")
    eq(seen[2], 1, "进子目录时 switchItemTable 之前 paths 就该就绪（否则 updatePageInfo 读到 0）")
    eq(#browser.paths, 1, "进入后 paths 应保持非空")
    eq(#seen, 2, "两次 enterPath 应各触发一次 switchItemTable")
end)

case("返回上一级（Bug2）：子目录首行是置顶的「⬆ ../」", function()
    local items = sortFixture()
    local browser = browserInDir({ "", "books" }, items)
    local first = browser.item_table[1]
    ok(first ~= nil, "应有首行")
    eq(first.is_go_up, true, "首行应是「返回上一级」导航行")
    contains(first.text, "../", "文案应含 ../")
    eq(first.name, "..", "名称应是 ..（与 KOReader 的 is_go_up 约定一致）")
    eq(first.is_file, false, "它不是文件（否则点击会走下载分支）")
    eq(first.is_folder, false, "它不是目录（否则点击会再次 enterPath）")
    eq(first.remote_path, "", "深层目录的 ../ 应指向父目录路径")
    eq(#browser.item_table, #items + 1, "在真实条目之外只多出 1 行")
end)

case("返回上一级（Bug2）：6 种排序键 × 升降序共 12 种组合，首行恒为「../」", function()
    local browser = browserInDir({ "", "books" })
    eq(#Sort.keys, 6, "前置：应有 6 种排序方式")

    for _, spec in ipairs(Sort.keys) do
        for _, descending in ipairs({ false, true }) do
            browser:setSort(spec.key, descending, true)
            local label = string.format("%s/%s", spec.key, descending and "降序" or "升序")
            local first = browser.item_table[1]
            eq(first and first.is_go_up, true, label .. "：首行应是「../」")
            contains(first and first.text or "", "../", label .. "：首行文案应含 ../")
            eq(countGoUp(browser.item_table), 1, label .. "：不应出现重复的「../」行")
        end
    end
end)

case("返回上一级（Bug2）：folders_first=false 混合排序时首行仍是「../」", function()
    local browser = browserInDir({ "", "books" })
    browser:setSort("name", false, false)
    eq(browser.sort_folders_first, false, "目录优先应已关闭")
    eq(browser.item_table[1].is_go_up, true, "目录与文件混排时首行仍应是「../」")
    eq(countGoUp(browser.item_table), 1, "混排时也只有一行")
    ok(browser.item_table[2].is_folder ~= true,
        "混排确实生效：第二行不应是目录（目录按名称落到后面）")

    browser:setSort("size", true, false)
    eq(browser.sort_folders_first, false, "size 降序下仍关闭目录优先")
    eq(browser.item_table[1].is_go_up, true, "size 降序 + 混排时首行仍是「../」")
end)

case("返回上一级（Bug2）：wdr/sort.lua 直接保证 is_go_up 恒在最前", function()
    local items = {
        { name = "b.txt", is_file = true, filesize = 10 },
        { name = "sub", is_folder = true },
        { text = "⬆ ../", name = "..", is_go_up = true },
        { name = "a.txt", is_file = true, filesize = 20 },
    }
    for _, spec in ipairs(Sort.keys) do
        for _, descending in ipairs({ false, true }) do
            local sorted = Sort.sortItems(items, {
                key = spec.key, descending = descending, folders_first = true,
            })
            local label = string.format("%s/%s", spec.key, descending and "降序" or "升序")
            eq(sorted[1].is_go_up, true, label .. "：is_go_up 应恒在最前")
            eq(#sorted, 4, label .. "：排序不应丢项")
        end
    end
    eq(Sort.sortItems(items, { key = "size", descending = true, folders_first = false })[1].is_go_up,
        true, "folders_first=false 时 is_go_up 仍置顶")
end)

case("返回上一级（Bug2）：点「../」回到根目录，行消失、箭头变禁用", function()
    local browser = browserInDir({ "", "books" })
    local go_up = browser.item_table[1]
    eq(go_up.is_go_up, true, "前置：首行是「../」")

    eq(browser:onMenuSelect(go_up), true, "点击应被消费（返回 true）")

    eq(browser.path, "", "应回到根目录")
    eq(#browser.dir_stack, 1, "栈深应减 1")
    eq(#browser.paths, 0, "回根后返回箭头应重新禁用")
    eq(countGoUp(browser.item_table), 0, "根目录不应再有「../」行")
    eq(#browser.item_table, #sortFixture(), "根目录只列真实条目")
    eq(#browser.manager.moved, 0, "回退不应触发任何移动/重命名")
    eq(#browser.manager.deleted, 0, "回退不应触发任何删除")
end)

case("返回上一级（Bug2）：长按「../」不弹文件管理菜单", function()
    local browser = browserInDir({ "", "books" })
    local go_up = browser.item_table[1]
    eq(go_up.is_go_up, true, "前置：首行是「../」")

    UIManagerStub.reset()
    eq(browser:onMenuHold(go_up), true, "长按应被消费（返回 true，不再冒泡）")
    eq(#UIManagerStub.shown, 0, "长按「../」不应弹出任何对话框")
    eq(browser.file_dialog, nil, "不应创建文件管理弹窗")

    -- 反证：长按真实目录确实会弹窗 —— 说明上面的 0 不是「整条链路没接上」
    UIManagerStub.reset()
    local folder = findItem(browser.item_table, "sub")
    ok(folder ~= nil, "应能找到真实目录项")
    browser:onMenuHold(folder)
    eq(#UIManagerStub.shown, 1, "长按真实目录应弹出管理菜单")
    eq(browser.file_dialog and browser.file_dialog.kind, "ButtonDialog", "应是按钮弹窗")
end)

case("返回上一级（Bug2）：栈深 3 时点「../」只退一层，箭头仍可点", function()
    local browser = browserInDir({ "", "books", "books/sub" })
    eq(#browser.dir_stack, 3, "前置：栈深 3")
    local go_up = browser.item_table[1]
    eq(go_up.is_go_up, true, "深层目录也应有「../」行")
    eq(go_up.remote_path, "books", "深层目录的 ../ 应指向 books 而不是根")

    browser:onMenuSelect(go_up)

    eq(#browser.dir_stack, 2, "应只退一层（不是一路退到根）")
    eq(browser.path, "books", "当前路径应是 books")
    eq(#browser.paths, 1, "还有上级可退 → 返回箭头仍可点")
    eq(countGoUp(browser.item_table), 1, "非根目录仍保留「../」行")
    contains(browser.item_table[1].text, "../", "首行仍是「../」")
end)

case("返回上一级（Bug2）：「../」行不影响其余项的实际排序结果", function()
    local browser = browserInDir({ "", "books" })
    browser:setSort("size", false, true)
    eq(browser.item_table[1].is_go_up, true, "前置：首行是「../」")

    local rest = {}
    for i = 2, #browser.item_table do rest[#rest + 1] = browser.item_table[i] end
    eq(namesOf(rest), "sub,b.txt,a10.txt,a.txt,a2.txt",
        "去掉首行后仍是 size 升序（目录优先 + 文件按大小）")

    local last_size = -1
    for i = 2, #browser.item_table do
        local it = browser.item_table[i]
        if it.is_file then
            ok((it.filesize or 0) >= last_size, "文件大小应递增：" .. tostring(it.name))
            last_size = it.filesize or 0
        end
    end
end)

case("返回上一级（Bug2）：「../」行不参与进度标记与文件管理字段", function()
    local browser = browserInDir({ "", "books" })
    local go_up = browser.item_table[1]
    eq(go_up.progress_entry, nil, "导航行不应有阅读进度条目")
    eq(go_up.progress_text, nil, "导航行不应有进度文本")
    eq(go_up.mandatory, nil, "导航行不应有 mandatory 附加文本（★/大小/日期）")
    eq(go_up.filesize, nil, "导航行不应有文件大小")

    local folder = findItem(browser.item_table, "sub")
    ok(folder ~= nil, "应有真实目录项")
    ok(folder.is_go_up ~= true, "真实目录项不应被误标 is_go_up")
end)

case("返回上一级（Bug2）：RTL 镜像布局下「../」文案方向正确", function()
    local browser = browserInDir({ "", "books" })
    eq(browser.item_table[1].text, "⬆ ../", "LTR 布局下箭头在左")

    -- 只改桩件状态、先恢复再断言，避免污染后续用例。用 pcall 包住，
    -- 这样即使 buildItemTable 抛错，全局的 _mirrored 也一定会被还原。
    local saved = BDStub._mirrored
    BDStub._mirrored = true
    local okk, err = pcall(function()
        browser:buildItemTable(browser.raw_items, browser.path)
    end)
    BDStub._mirrored = saved
    ok(okk, "镜像布局下重建列表不应抛错：" .. tostring(err))

    eq(browser.item_table[1].text, "../ ⬆", "镜像布局下箭头应在右侧（经 BD.ltr 包裹）")
    eq(browser.item_table[1].is_go_up, true, "镜像布局下仍是置顶导航行")
    eq(BDStub._mirrored, saved, "用例结束必须还原桩件状态，避免污染后续用例")
end)

-- ---------------------------------------------------------------------------
-- 用例 10：恢复上次浏览位置（回归：深层目录恢复后「返回上一级」三条退路全失效）
--
-- 这是用例 9 那类 bug 的第二个入口，也是用户实际最容易踩到的入口：
-- main.lua 的 openBrowserFor 会把 Session.getLastPath 恢复出来的路径直接交给
-- enterPath。而 enterPath 只改 self.path，不动 dir_stack（它恒为 {""}），
-- 于是「返回上一级」的全部判据（#dir_stack > 1）都为假：
--   * buildItemTable 不插入置顶「⬆ ../」行；
--   * syncMenuPaths 让左下角箭头保持 disabled（点了没反应）；
--   * 目录菜单里的「上一级」是灰的；
--   * onReturn 还会走进 onClose() 分支 —— 在 books/deep 里按返回 = 直接关界面。
-- 用户明明在深层目录，三条退路却同时消失，比原报的还严重。
--
-- 修法：Browser:rebuildDirStack(path) 按路径段数重建栈（根 "" + 每段累积），
-- Browser:openPathAt(path, do_show) = rebuildDirStack + enterPath，
-- openBrowserFor / openServer / enterPath 的回退分支都改用它。
-- ---------------------------------------------------------------------------

--- 造一个「插件实例 + 独立服务器 + 可列举的假 client」，用于走 openBrowserFor。
-- 每个用例用独立 address，避免 Session.last_paths / 进度互相串味。
-- @param prefix string 服务器名前缀
-- @param start_dir string|nil 服务器起始目录（默认 "/"）
-- @return table plugin, number idx, string address
local function newRestorePlugin(prefix, start_dir)
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    TEST_SERVER_SEQ = TEST_SERVER_SEQ + 1
    local address = string.format("http://restore%d.example.test/dav", TEST_SERVER_SEQ)
    local idx = Config:addServer({
        name = (prefix or "恢复测试") .. TEST_SERVER_SEQ,
        address = address,
        username = "u",
        password = "p",
        start_dir = start_dir or "/",
    })
    -- 任意目录都列举成功（本用例只关心导航栈，不关心内容）
    plugin.getClientFor = function()
        return {
            list = function(_, p)
                local dir = (p == nil or p == "") and "" or (p .. "/")
                return {
                    { name = "a.txt", is_folder = false, path = dir .. "a.txt", size = 10 },
                }
            end,
        }
    end
    return plugin, idx, address
end

--- 模拟「上次浏览到 last_path 后关闭，现在重新打开该服务器」。
-- @return table browser（插件的 self.browser）, table plugin
local function restoreBrowser(last_path, opts)
    opts = opts or {}
    local plugin, idx, address = newRestorePlugin(opts.prefix, opts.start_dir)
    Session.setLastPath(address, last_path)
    plugin:openBrowserFor(idx)
    return plugin.browser, plugin
end

case("恢复上次位置：深层 books/deep 恢复后三条退路都应可用", function()
    local browser = restoreBrowser("books/deep")

    -- 1) 路径与导航栈必须自洽（这是本次修复的核心）
    eq(browser.path, "books/deep", "应恢复到 books/deep")
    eq(#browser.dir_stack, 3, "栈深应是 3（根 + 两级目录），修复前恒为 1")
    eq(table.concat(browser.dir_stack, ","), ",books,books/deep", "栈内容应是逐级累积的路径")
    eq(browser.dir_stack[1], "", "栈底应是根目录")
    eq(browser.dir_stack[3], "books/deep", "栈顶应是当前目录")

    -- 2) 左下角返回箭头（Bug 1 的判据）
    eq(#browser.paths, 1, "paths 应非空 → 左下角箭头可点（修复前是 0，点了没反应）")
    eq(browser.paths[1], true, "占位元素应是 true")

    -- 3) 置顶「⬆ ../」行（Bug 2 的判据）
    local first = browser.item_table[1]
    eq(first.is_go_up, true, "首行应是「⬆ ../」（修复前根本没有这一行）")
    contains(first.text, "../", "首行文案应含 ../")
    eq(first.remote_path, "books", "深层目录的 ../ 应指向父目录 books")
    eq(countGoUp(browser.item_table), 1, "应恰好一行「../」")
end)

case("恢复上次位置：单层 books 恢复后栈深 2、箭头可点", function()
    local browser = restoreBrowser("books")
    eq(browser.path, "books", "应恢复到 books")
    eq(#browser.dir_stack, 2, "栈深应是 2")
    eq(table.concat(browser.dir_stack, ","), ",books", "栈内容")
    eq(#browser.paths, 1, "箭头应可点")
    eq(browser.item_table[1].is_go_up, true, "应有「../」行")
    eq(browser.item_table[1].remote_path, "", "单层目录的 ../ 应指向根")
end)

case("恢复上次位置：根目录恢复后栈深 1、箭头禁用、无「../」行", function()
    -- start_dir 显式给 "/"，否则 openBrowserFor 会把空 target 回填成 start_dir
    local browser = restoreBrowser("", { start_dir = "/" })
    eq(browser.path, "", "应恢复到根目录")
    eq(#browser.dir_stack, 1, "栈深应是 1")
    eq(#browser.paths, 0, "根目录箭头应禁用")
    eq(countGoUp(browser.item_table), 0, "根目录不应有「../」行")
    ok(browser.item_table[1].is_go_up ~= true, "首行应是真实条目")
    eq(#browser.item_table, 1, "根目录只列真实条目")
end)

case("恢复上次位置：在深层目录点「../」应退回上一级，而不是关掉界面", function()
    local browser = restoreBrowser("books/deep")
    eq(browser.item_table[1].is_go_up, true, "前置：首行是「../」")
    eq(browser.closed, nil, "前置：界面应是打开的")

    eq(browser:onMenuSelect(browser.item_table[1]), true, "点击应被消费")

    -- 修复前这里会走 onClose()：path 不变、界面被关掉，用户直接掉出浏览界面
    eq(browser.closed, nil, "点「../」绝不能关掉界面（修复前会走 onClose 分支）")
    eq(browser.path, "books", "应退到上一级 books")
    eq(#browser.dir_stack, 2, "栈深应减到 2")
    eq(browser.dir_stack[2], "books", "栈顶应是 books")
    eq(#browser.paths, 1, "还有上级可退 → 箭头仍可点")
    eq(browser.item_table[1].is_go_up, true, "非根目录仍应有「../」行")
end)

case("恢复上次位置：连续点两次「../」退回根，paths 清空且全程不关界面", function()
    local browser = restoreBrowser("books/deep")
    eq(#browser.dir_stack, 3, "前置：栈深 3")

    browser:onMenuSelect(browser.item_table[1])
    eq(browser.path, "books", "第一次退到 books")
    eq(#browser.dir_stack, 2, "第一次后栈深 2")

    browser:onMenuSelect(browser.item_table[1])
    eq(browser.path, "", "第二次应退回根目录")
    eq(#browser.dir_stack, 1, "第二次后栈深 1")
    eq(#browser.paths, 0, "回根后 paths 应清空 → 箭头重新禁用")
    eq(countGoUp(browser.item_table), 0, "回根后「../」行应消失")
    eq(browser.closed, nil, "两次回退都不应关掉界面")

    -- 已在根目录时，「返回上一级」的语义是「关闭界面」（而不是什么都不做）
    browser:onReturn()
    eq(browser.closed, true, "根目录下 onReturn 应关闭界面（有明确反馈，不是无反应）")
    eq(browser.path, "", "关闭前路径仍是根")
end)

case("恢复上次位置：深层目录的目录菜单「上一级」应可点", function()
    local browser = restoreBrowser("books/deep")
    browser:showFolderMenu()
    local dialog = UIManagerStub.last_widget
    eq(dialog.kind, "ButtonDialog", "应弹出目录菜单")
    local btn = buttonByText(dialog, "上一级")
    ok(btn ~= nil, "目录菜单应有「上一级」")
    ok(btn.enabled ~= false, "深层目录里「上一级」应可点（修复前是 false/灰的）")
    eq(btn.enabled, true, "enabled 应是明确的 true")
    eq(type(btn.callback), "function", "「上一级」应挂回调")

    -- 点它确实能退回上一级
    btn.callback()
    eq(browser.path, "books", "点目录菜单「上一级」应退回 books")
    eq(#browser.dir_stack, 2, "栈深应减到 2")

    -- 反证：根目录下「上一级」才是禁用的（说明上面的 true 不是恒真）
    local root_browser = restoreBrowser("", { start_dir = "/" })
    root_browser:showFolderMenu()
    local root_btn = buttonByText(UIManagerStub.last_widget, "上一级")
    ok(root_btn ~= nil, "根目录也应有「上一级」项")
    eq(root_btn.enabled, false, "根目录下「上一级」应禁用")
end)

case("rebuildDirStack：按路径段数重建导航栈（含斜杠规范化的边界）", function()
    local browser = newTestBrowser{ items = sortFixture() }

    local cases = {
        { path = "",        depth = 1, stack = "" },
        { path = "a",       depth = 2, stack = ",a" },
        { path = "a/b/c",   depth = 4, stack = ",a,a/b,a/b/c" },
        { path = "/a/b/",   depth = 3, stack = ",a,a/b" },      -- 首尾斜杠要去掉
        { path = "a//b",    depth = 3, stack = ",a,a/b" },      -- 重复斜杠要压缩
        { path = "/",       depth = 1, stack = "" },
        { path = "///",     depth = 1, stack = "" },
        { path = "a/b/",    depth = 3, stack = ",a,a/b" },
        { path = "/a/b/c/d/", depth = 5, stack = ",a,a/b,a/b/c,a/b/c/d" },
    }
    for _, c in ipairs(cases) do
        local st = browser:rebuildDirStack(c.path)
        eq(#st, c.depth, string.format("rebuildDirStack(%q) 深度", c.path))
        eq(table.concat(st, ","), c.stack, string.format("rebuildDirStack(%q) 栈内容", c.path))
        eq(st, browser.dir_stack, string.format("rebuildDirStack(%q) 应原地返回同一张表", c.path))
    end

    -- 返回 nil / 缺参时按根目录处理，不应抛错
    local okk, err = pcall(function() browser:rebuildDirStack(nil) end)
    ok(okk, "rebuildDirStack(nil) 不应抛错：" .. tostring(err))
    eq(#browser.dir_stack, 1, "nil 路径应视为根目录")
end)

case("openPathAt：先重建栈再进入目录，结果与 rebuildDirStack 一致", function()
    local browser = newTestBrowser{ items = sortFixture() }

    -- 不显示界面（do_show=false），避免只验证导航接线
    browser:openPathAt("a/b/c", false)
    eq(browser.path, "a/b/c", "应进入目标目录")
    eq(#browser.dir_stack, 4, "栈深应跟着路径走")
    eq(table.concat(browser.dir_stack, ","), ",a,a/b,a/b/c", "栈内容应逐级累积")

    -- 与 rebuildDirStack 的独立计算结果必须一致
    local expected = {}
    for i, v in ipairs((function()
        local tmp = newTestBrowser{ items = sortFixture() }
        return tmp:rebuildDirStack("a/b/c")
    end)()) do expected[i] = v end
    eq(table.concat(browser.dir_stack, ","), table.concat(expected, ","),
        "openPathAt 的栈应与 rebuildDirStack 完全一致")

    -- 跳回浅层路径时栈必须缩短（不能残留更深的历史层级）
    browser:openPathAt("a", false)
    eq(browser.path, "a", "应进入 a")
    eq(#browser.dir_stack, 2, "栈应缩短到 2（不残留 a/b/c）")
    eq(#browser.paths, 1, "箭头应可点")
    eq(browser.item_table[1].is_go_up, true, "应有「../」行")

    -- 跳到根时栈清空、箭头禁用
    browser:openPathAt("", false)
    eq(browser.path, "", "应回到根")
    eq(#browser.dir_stack, 1, "栈应只剩根")
    eq(#browser.paths, 0, "箭头应禁用")
    eq(countGoUp(browser.item_table), 0, "根目录不应有「../」行")
end)

case("openServer：按 start_dir 深度重建栈（不再硬写 {  \"\" }）", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local plugin, idx = newRestorePlugin("openServer", "/books/deep")
    local browser = Browser:new{
        plugin = plugin, config = Config, progress = Progress, cache = Cache,
        manager = FakeManager.new(), server_idx = idx,
    }
    plugin.browser = browser
    browser:openServer(idx)

    eq(browser.path, "books/deep", "应打开 start_dir")
    eq(#browser.dir_stack, 3, "栈深应与 start_dir 的层级一致")
    eq(#browser.paths, 1, "箭头应可点")
    eq(browser.item_table[1].is_go_up, true, "应有「../」行")
end)

case("恢复上次位置：进入失败时回退到起始目录，栈跟着重建（不崩、不指错层级）", function()
    -- 两个 bug 在这里叠加：
    --   * 回退目标比原目标浅，dir_stack 必须跟着重建，否则「返回上一级」指向不存在的层级；
    --   * browser.lua 顶部有 local _ = require("gettext")，回退分支的循环变量若写成 "_"
    --     就会把它遮蔽，导致该分支里的 T(_("...")) 抛 attempt to call local '_'。
    -- 这个用例同时钉住「不崩」与「栈对」。
    local plugin, idx, address = newRestorePlugin("回退测试", "/books")
    -- 让深层目录列举失败、浅层目录成功，触发回退
    plugin.getClientFor = function()
        return {
            list = function(_, p)
                if p == "books/deep" then return nil, "not found" end
                return {
                    { name = "a.txt", is_folder = false, path = "a.txt", size = 10 },
                }
            end,
        }
    end
    Session.setLastPath(address, "books/deep")

    local okk, err = pcall(function() plugin:openBrowserFor(idx) end)
    ok(okk, "回退分支不应抛异常（曾因 gettext 局部量被循环变量遮蔽而崩溃）：" .. tostring(err))

    local browser = plugin.browser
    eq(browser.path, "books", "应回退到 server.start_dir")
    eq(#browser.dir_stack, 2, "栈应按回退后的路径重建（不是停留在原目标的 3 层）")
    eq(table.concat(browser.dir_stack, ","), ",books", "栈内容应指向 books")
    eq(#browser.paths, 1, "回退后箭头应可点")
    eq(browser.item_table[1].is_go_up, true, "回退后应有「../」行")
    eq(browser.item_table[1].remote_path, "", "books 的 ../ 应指向根")

    -- 提示文案必须真的渲染出替换后的路径（模板参数未被遮蔽才会正常）
    ok(UIManagerStub.last_message, "应提示已回退")
    contains(UIManagerStub.last_message.text, "已回到", "提示应说明已回到某目录")
    contains(UIManagerStub.last_message.text, "/books", "提示应带上实际路径（模板参数必须被替换）")
end)

-- ---------------------------------------------------------------------------
-- 用例 11：gettext `_` 被循环占位变量遮蔽 → 延迟闭包一被调用就崩（行为级回归）
--
-- 这是一类只在「运行时」才暴露的 bug：main.lua / browser.lua / history.lua 顶部都有
--     local _ = require("gettext")
-- 而某些循环把它当成「用不到的占位变量」写成
--     for _, e in ipairs(entries) do ...
-- 于是循环体（以及循环体内定义的、稍后才被点击的闭包）里的 `_` 变成了 ipairs 的
-- 索引（数字）。用户点下去那一刻才执行闭包里的 `_("...")`，抛
--     attempt to call local '_' (a number value)
-- 三处用户真会撞上的入口：
--   1. 点「阅读进度记录」里任意条目 → 崩；
--   2. 点「移动位置记录」里任意条目 → 崩；
--   3. 首次进目录失败、需要回退到 start_dir / 根目录时 → 整个浏览界面崩。
--
-- 静态扫描（tests/test_shadow.lua）只能防「新写出 for _,」，防不了闭包逻辑本身错、
-- 文案漏传参数。所以这里全部做行为级验证：**真的执行那个回调**，并用 pcall 包住——
-- 否则用例本身会被异常打断，反而看不出是被测代码崩还是测试写错。
-- ---------------------------------------------------------------------------

local PROGRESS_SEQ = 0

--- 每个进度用例用一份独立 JSON，返回 (path, 清场函数)。
-- 清场函数删掉临时文件并把 Progress 还原到用例之前的那份 store，
-- 避免污染后面的用例。
local function isolatedProgress()
    PROGRESS_SEQ = PROGRESS_SEQ + 1
    local path = "/tmp/wdr_ui_test_data/progress_shadow_" .. PROGRESS_SEQ .. ".json"
    os.remove(path)
    local saved = Progress.path
    Progress:init(path)
    return path, function()
        os.remove(path)
        if saved then Progress:init(saved) end
    end
end

--- 在按钮弹窗里按「文案包含」找按钮（比精确匹配更耐受 %/后缀变化）。
local function buttonContaining(dialog, needle)
    for _, row in ipairs((dialog and dialog.buttons) or {}) do
        for _, btn in ipairs(row) do
            if btn and type(btn.text) == "string" and btn.text:find(needle, 1, true) then
                return btn
            end
        end
    end
    return nil
end

--- 执行一个按钮回调，并断言它不抛异常。
-- 关键：必须走 pcall。遮蔽 bug 只在闭包被调用时才暴露，如果不 pcall，
-- 用例会直接中断，失败信息只会是「抛出异常」，分不清是生产代码崩还是测试写错。
-- @return boolean 回调是否正常返回
local function invokeCallback(btn, label)
    ok(btn ~= nil, (label or "回调") .. "：应能找到按钮")
    if not btn then return false end
    ok(type(btn.callback) == "function", (label or "回调") .. "：按钮应挂回调")
    if type(btn.callback) ~= "function" then return false end
    local okk, err = pcall(btn.callback)
    ok(okk, (label or "回调") .. "：回调不应抛异常（`_` 被遮蔽时这里会崩）：" .. tostring(err))
    return okk
end

--- 执行确认框的 ok_callback，并断言它不抛异常。
-- @return boolean 是否正常返回
local function invokeOkCallback(confirm, label)
    ok(confirm ~= nil, (label or "确认框") .. "：应弹出确认框")
    if not confirm then return false end
    ok(type(confirm.ok_callback) == "function", (label or "确认框") .. "：应有 ok_callback")
    if type(confirm.ok_callback) ~= "function" then return false end
    local okk, err = pcall(confirm.ok_callback)
    ok(okk, (label or "确认框") .. "：ok_callback 不应抛异常（`_` 被遮蔽时这里会崩）："
        .. tostring(err))
    return okk
end

case("遮蔽回归：点「阅读进度记录」任意条目不崩，且信息完整", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    local _, cleanup = isolatedProgress()

    local idx = Config:addServer({
        name = "进度服务器甲",
        address = "http://shadow-progress.example.test/dav",
        username = "u", password = "p",
    })
    local server = Config:getServer(idx)
    Progress:save(server, "books/a.txt", { percent = 0.42, page = 12 })
    Progress:save(server, "papers/b.epub", { percent = 0.07 })
    eq(#Progress:list(), 2, "前置：应有 2 条进度记录")

    plugin:showProgressList()
    local dialog = UIManagerStub.last_widget
    eq(dialog.kind, "ButtonDialog", "应弹出进度列表弹窗")
    contains(dialog.title, "阅读进度", "标题应说明这是阅读进度")
    contains(dialog.title, "（2 条）", "标题应带条数（模板参数必须被替换）")

    -- 真正执行条目回调：遮蔽 bug 就藏在这个闭包里
    local btn = buttonContaining(dialog, "books/a.txt")
    invokeCallback(btn, "点进度条目")

    eq(UIManagerStub.last_widget.kind, "InfoMessage", "点条目应弹出说明而不是按钮弹窗")
    local text = UIManagerStub.last_widget.text or ""
    contains(text, "文件：", "应显示文件行")
    contains(text, "books/a.txt", "应显示远程路径")
    contains(text, "进度服务器甲", "应显示服务器名")
    contains(text, "42%", "应显示百分比（模板参数必须被替换）")
    contains(text, "更新时间：", "应显示更新时间")
    cleanup()
end)

case("遮蔽回归：清空全部进度的 ok_callback 不崩", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    local _, cleanup = isolatedProgress()

    local idx = Config:addServer({
        name = "进度服务器乙",
        address = "http://shadow-progress-clear.example.test/dav",
        username = "u", password = "p",
    })
    local server = Config:getServer(idx)
    Progress:save(server, "books/c.txt", { percent = 0.5 })
    eq(#Progress:list(), 1, "前置：应有 1 条进度记录")

    plugin:showProgressList()
    invokeCallback(buttonByText(UIManagerStub.last_widget, "清空全部进度"), "点「清空全部进度」")

    local confirm = UIManagerStub.last_widget
    eq(confirm.kind, "ConfirmBox", "应弹出确认框")
    eq(confirm.ok_text, "删除", "确认按钮文案")
    contains(confirm.text, "删除所有阅读进度记录？", "确认文案应说明删除范围")
    contains(confirm.text, "远程文件与缓存不受影响。", "确认文案应说明不影响远程文件")

    invokeOkCallback(confirm, "清空全部进度")
    eq(#Progress:list(), 0, "执行后应清空全部进度")
    ok(UIManagerStub.last_notification, "应给出通知")
    contains(UIManagerStub.last_notification.text, "已清空", "通知应说明已清空")
    cleanup()
end)

case("遮蔽回归：点「移动位置记录」任意条目不崩，确认框文案完整", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    freshHistoryStore()
    local server = Config:getServer(1)
    eq(History:add(server, "books/done"), true, "应能写入一条历史")
    eq(History:add(server, "papers/2024"), true, "应能写入第二条历史")

    plugin:showMoveHistory()
    local dialog = UIManagerStub.last_widget
    eq(dialog.kind, "ButtonDialog", "应弹出移动位置记录弹窗")
    contains(dialog.title, "移动位置记录", "标题应说明这是移动位置记录")
    contains(dialog.title, "（2 条）", "标题应带条数（模板参数必须被替换）")

    -- 真正执行条目回调：遮蔽 bug 就藏在这个闭包里
    invokeCallback(buttonByText(dialog, "/books/done"), "点移动历史条目")

    local confirm = UIManagerStub.last_widget
    eq(confirm.kind, "ConfirmBox", "应弹出确认框")
    eq(confirm.ok_text, "移除", "确认按钮文案")
    contains(confirm.text, "从历史中移除 /books/done？", "确认文案应带上目标目录（模板参数必须被替换）")
    contains(confirm.text, "不会删除服务器上的任何文件", "确认文案应说明不删远程文件")
    eq(#History:list(server), 2, "只是弹确认框，此时还不应删掉记录")
end)

case("遮蔽回归：确认移除的 ok_callback 真的少一条且不崩", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    freshHistoryStore()
    local server = Config:getServer(1)
    History:add(server, "books/done")
    History:add(server, "papers/2024")
    eq(#History:list(server), 2, "前置：应有 2 条历史")

    plugin:showMoveHistory()
    invokeCallback(buttonByText(UIManagerStub.last_widget, "/books/done"), "点移动历史条目")
    local confirm = UIManagerStub.last_widget

    invokeOkCallback(confirm, "确认移除")
    local list = History:list(server)
    eq(#list, 1, "执行后应少一条历史")
    eq(list[1].dir, "papers/2024", "留下的应是另一条")
    ok(UIManagerStub.last_notification, "应给出通知")
    contains(UIManagerStub.last_notification.text, "已移除", "通知应说明已移除")
end)

case("遮蔽回归：清空全部移动记录的 ok_callback 不崩（History:clear 的 pairs 循环）", function()
    local Main = dofile("webdavreader.koplugin/main.lua")
    local plugin = Main:new{ ui = FakeUI.new() }
    freshHistoryStore()
    local server = Config:getServer(1)
    History:add(server, "books/done")
    History:add(server, "papers/2024")

    plugin:showMoveHistory()
    invokeCallback(buttonByText(UIManagerStub.last_widget, "清空全部移动记录"),
        "点「清空全部移动记录」")

    local confirm = UIManagerStub.last_widget
    eq(confirm.kind, "ConfirmBox", "应弹出确认框")
    eq(confirm.ok_text, "清空", "确认按钮文案")
    contains(confirm.text, "清空 2 条移动位置记录？", "确认文案应带条数（模板参数必须被替换）")
    contains(confirm.text, "不会删除服务器上的任何文件", "确认文案应说明不删远程文件")

    invokeOkCallback(confirm, "清空全部移动记录")
    eq(#History:list(server), 0, "执行后该服务器的历史应被清空")
    ok(UIManagerStub.last_notification, "应给出通知")
    contains(UIManagerStub.last_notification.text, "已清空", "通知应说明已清空")
end)

-- ---------------------------------------------------------------------------
-- 用例 12：browser 的「进入失败 → 回退」分支（最容易回归的一处）
--
-- browser.lua 顶部同样有 local _ = require("gettext")。回退分支写成
--     for _, candidate in ipairs(candidates) do ... T(_("...")) ...
-- 时，成功的那一轮里 `_` 是索引（数字），T(_("...")) 一执行就崩 ——
-- 表现为「首次进入某个目录失败、需要回退时，整个浏览界面崩掉」。
--
-- 这里覆盖回退分支的三种形态，并且都**直接调 enterPath(target, true)**，
-- 确保走到的是 do_show=true 的回退逻辑：
--   a) start_dir 也失败 → 第 2 轮才回退到根目录（能钉住「循环第一轮不崩、第二轮也崩」）；
--   b) start_dir 成功 → 第 1 轮就回退到 start_dir，且 dir_stack 必须跟着重建；
--   c) 全部候选都失败 → 不崩，给明确错误，栈逐级收敛到根。
-- ---------------------------------------------------------------------------

--- 造一个「只有 ok_paths 里的目录能列举成功」的 browser，用于 enterPath 回退分支。
-- @param prefix string 服务器名前缀（保证各用例地址唯一）
-- @param start_dir string 服务器起始目录
-- @param ok_paths table 可列举成功的路径集合，键为归一化路径（"" 表示根）
-- @return table browser, table plugin, number idx
local function newFallbackBrowser(prefix, start_dir, ok_paths)
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")
    local plugin, idx = newRestorePlugin(prefix, start_dir)
    plugin.getClientFor = function()
        return {
            list = function(_, p)
                local norm = (p == nil) and "" or p
                if ok_paths[norm] then
                    local base = norm == "" and "" or (norm .. "/")
                    return {
                        { name = "a.txt", is_folder = false, path = base .. "a.txt", size = 10 },
                    }
                end
                return nil, "not found"
            end,
        }
    end
    local browser = Browser:new{
        plugin = plugin, config = Config, progress = Progress, cache = Cache,
        manager = FakeManager.new(), server_idx = idx,
        title_bar_left_icon = "appbar.menu",
    }
    plugin.browser = browser
    return browser, plugin, idx
end

case("遮蔽回归：enterPath 回退到根目录不崩（第 2 轮候选才成功）", function()
    -- start_dir="books/deep" 也列举失败，只有根目录成功 → 回退循环会先失败一轮、
    -- 第二轮才执行到 T(_("无法打开请求的目录，已回到 /%1"))。
    local browser = newFallbackBrowser("回退直调根", "/books/deep", { [""] = true })
    browser.dir_stack = { "", "target", "target/sub" }
    browser.path = "target/sub"

    local okk, err = pcall(function() browser:enterPath("target/sub", true) end)
    ok(okk, "回退分支不应抛异常（`_` 被遮蔽时这里会崩）：" .. tostring(err))

    eq(browser.path, "", "start_dir 也失败 → 应回退到根目录")
    eq(#browser.dir_stack, 1, "栈应与回退后的路径一致（只剩根，不残留 target/sub）")
    eq(table.concat(browser.dir_stack, ","), "", "栈内容应是根")
    eq(#browser.paths, 0, "根目录左下角箭头应禁用")
    eq(browser._fallback_tried, nil, "回退成功后必须复位标记，否则下次失败无法再回退")
    eq(countGoUp(browser.item_table), 0, "根目录不应有「../」行")

    ok(UIManagerStub.last_message, "应提示已回退")
    contains(UIManagerStub.last_message.text, "已回到", "提示应说明已回到某目录")
    ok(UIManagerStub.last_message.text:find("已回到 /$") ~= nil,
        "回退到根目录时应显示「已回到 /」：" .. tostring(UIManagerStub.last_message.text))
end)

case("遮蔽回归：enterPath 回退到 start_dir 不崩，且栈与回退路径层级一致", function()
    local browser = newFallbackBrowser("回退直调起始", "/books/deep",
        { [""] = true, ["books/deep"] = true })
    browser.dir_stack = { "", "target", "target/sub" }
    browser.path = "target/sub"

    local okk, err = pcall(function() browser:enterPath("target/sub", true) end)
    ok(okk, "回退分支不应抛异常（`_` 被遮蔽时这里会崩）：" .. tostring(err))

    eq(browser.path, "books/deep", "应回退到 server.start_dir")
    eq(#browser.dir_stack, 3, "栈应按回退后的路径重建（不是停留在原目标的 3 层空壳）")
    eq(table.concat(browser.dir_stack, ","), ",books,books/deep", "栈内容应逐级累积到 books/deep")
    eq(#browser.paths, 1, "回退到非根目录 → 左下角箭头应可点")
    eq(browser.item_table[1].is_go_up, true, "回退到非根目录应有「../」行")
    eq(browser.item_table[1].remote_path, "books", "books/deep 的 ../ 应指向 books")
    ok(UIManagerStub.last_message, "应提示已回退")
    contains(UIManagerStub.last_message.text, "已回到", "提示应说明已回到")
    contains(UIManagerStub.last_message.text, "/books/deep",
        "提示应带上实际路径（模板参数必须被替换）")
end)

case("遮蔽回归：回退候选全部失败也不崩，错误明确且只退一层（不弹空栈）", function()
    local browser = newFallbackBrowser("回退直调全失败", "/books/deep", {})
    browser.dir_stack = { "", "a", "a/b" }
    browser.path = "a/b"

    local okk, err = pcall(function() browser:enterPath("a/b", true) end)
    ok(okk, "全部候选失败也不应抛异常：" .. tostring(err))
    ok(UIManagerStub.last_message, "应提示读取失败")
    contains(UIManagerStub.last_message.text, "无法读取目录内容", "提示应说明读取失败")
    -- 候选全失败后才走到末尾的「回退上一级」：那里递归调用 enterPath 时没有传 do_show，
    -- 所以只会退一层（3 → 2），不会一路退到根。这里钉住「确实退了一层、且栈没被弹空」。
    eq(#browser.dir_stack, 2, "应退掉一层（3 → 2），且不能把栈弹空")
    eq(browser.dir_stack[1], "", "栈底必须仍是根目录")
    eq(browser.dir_stack[2], "a", "栈顶应是父目录 a")
    eq(browser._fallback_tried, nil, "失败路径也要复位 _fallback_tried")
end)

case("遮蔽回归：回退成功后再次失败仍能回退（_fallback_tried 必须复位）", function()
    local browser = newFallbackBrowser("回退直调二次", "/books",
        { [""] = true, ["books"] = true })

    local ok1 = pcall(function() browser:enterPath("x/y", true) end)
    ok(ok1, "第一次回退不应抛异常")
    eq(browser.path, "books", "第一次应回退到 start_dir")
    eq(browser._fallback_tried, nil, "回退成功后标记必须复位")

    local ok2 = pcall(function() browser:enterPath("x/y", true) end)
    ok(ok2, "第二次回退也不应抛异常（标记没复位的话这里会直接失败而不回退）")
    eq(browser.path, "books", "第二次仍应回退到 books")
    eq(#browser.dir_stack, 2, "栈仍应与 books 一致")
end)

-- ---------------------------------------------------------------------------
-- 用例 13：排序偏好持久化（回归：saveState 整表覆盖把 sort_* 抹掉）
--
-- 用户报障：「排序选项无法保留」。给过精确复现路径：
--   在浏览文件界面点开一本书 → 先返回本地文件夹 → 短暂时间后回到浏览界面
--   → 排序已经变回默认了。
--
-- 根因（main.lua:saveState）：排序偏好（sort_key / sort_descending /
-- sort_folders_first）由 saveSortSettings 写进 webdavreader_state.lua，而
-- openRemoteFile（也就是「点开一本书」这个动作）会调 saveState。早先的实现是
--     writeState{ last_server_idx=..., last_paths=..., local_map=... }  -- 整表覆盖
-- 于是「打开一本书」顺手把用户的排序设置抹掉了；另外 Session.last_server_idx
-- 在某些调用路径上是 nil，把 nil 赋给键等于删键，磁盘上已有的值也会一起没。
--
-- 修法见 main.lua:saveState（读-改-写合并，且 nil 不覆盖已有值）。下面这些用例
-- 就是钉死它：谁把 saveState 改回整表覆盖，A2 的第一条核心断言立刻变红。
--
-- 测试卫生（重要）：webdavreader_state.lua 是固定路径
-- （DataStorage:getSettingsDir()/webdavreader_state.lua），用例之间会互相污染，
-- 所以每个用例开头都必须显式删文件 + Session.reset()。
-- ---------------------------------------------------------------------------

--- 读状态文件的原始文本（用来断言「真的落盘了」，而不只是内存里有值）。
-- @param path string
-- @return string|nil
local function readStateRaw(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local content = fh:read("*all")
    fh:close()
    return content
end

--- 清掉固定路径的状态文件并重置会话（排序持久化用例的统一前置）。
-- @return table Main（插件类）, string path（状态文件绝对路径）
local function freshState()
    local Main = dofile("webdavreader.koplugin/main.lua")
    -- 用生产代码自己的方法取路径，避免在测试里硬编码目录结构
    local path = Main.getStatePath(Main)
    os.remove(path)
    Session.reset()
    return Main, path
end

--- 新建一份「刚启动」的插件实例（init 里会 loadState）。
-- @return table plugin, table Main
local function newStatePlugin()
    local Main, _ = freshState()
    return Main:new{ ui = FakeUI.new() }, Main
end

--- 模拟进程重启：清空模块级 Session 后新建插件实例（init 里重新 loadState）。
-- 注意先 reset 再 new：否则 new 里的 loadState 会读到上一个用例残留的会话。
-- @return table plugin, table Main
local function restartStatePlugin()
    local Main = dofile("webdavreader.koplugin/main.lua")
    Session.reset()
    return Main:new{ ui = FakeUI.new() }, Main
end

--- 造一个「任意目录都返回同一批条目」的假 client，并把 path 补成相对当前目录。
-- @param items table 条目数组（name / is_folder / size / modified / created）
-- @return table client
local function fakeClientFor(items)
    return {
        list = function(_, path)
            local base = (path == nil or path == "") and "" or (path .. "/")
            local out = {}
            for item_idx, it in ipairs(items or {}) do
                local copy = {}
                for k, v in pairs(it) do copy[k] = v end
                copy.path = base .. it.name
                out[item_idx] = copy
            end
            return out
        end,
    }
end

--- 排序持久化夹具：名称顺序（a<b<c<d）与大小顺序（d>c>b>a）刻意相反，
-- 这样「排序键真的生效了」与「回退成默认按名称」在断言上能区分开。
local function persistFixture()
    return {
        { name = "sub", is_folder = true },
        { name = "a.txt", is_folder = false, size = 100, modified = 4000, created = 1000 },
        { name = "b.txt", is_folder = false, size = 200, modified = 3000, created = 2000 },
        { name = "c.txt", is_folder = false, size = 300, modified = 2000, created = 3000 },
        { name = "d.txt", is_folder = false, size = 400, modified = 1000, created = 4000 },
    }
end

case("排序持久化 A1：saveSortSettings 三个键都立即落盘", function()
    local plugin, Main = newStatePlugin()
    local path = Main.getStatePath(Main)
    eq(readStateRaw(path), nil, "前置：状态文件应不存在")

    plugin:saveSortSettings("size", true, false)

    ok(readStateRaw(path) ~= nil, "saveSortSettings 应立即创建状态文件")
    contains(readStateRaw(path), "sort_key", "原始文件里应真的有 sort_key 这一行")
    local st = plugin:readState()
    ok(st ~= nil, "应能读回状态")
    eq(st.sort_key, "size", "排序键")
    eq(st.sort_descending, true, "方向：降序")
    eq(st.sort_folders_first, false, "目录优先：关（必须真的写成 false，不能是 nil）")
    -- 读 API 与写 API 必须一致，尤其 false 不能被当成「没有值」
    eq(plugin:readSetting("sort_key"), "size", "readSetting 应与 readState 一致")
    eq(plugin:readSetting("sort_folders_first"), false, "false 不能被 readSetting 变成 nil")
end)

case("排序持久化 A2（核心回归）：打开一本书不得抹掉排序偏好", function()
    local plugin = newStatePlugin()
    local idx, server = addTestServer("排序持久化核心")
    plugin.getClientFor = function() return fakeClientFor(persistFixture()) end
    Session.last_server_idx = idx

    plugin:saveSortSettings("size", true, false)
    eq(plugin:readSetting("sort_key"), "size", "前置：排序已写入磁盘")

    -- 用户「点开一本书」：这条路径里 openRemoteFile 会调 saveState()
    plugin:openRemoteFile(server, {
        name = "b.txt", is_file = true, remote_path = "books/b.txt",
    }, "/tmp/wdr_ui_test_data/open/books_b.txt")

    -- 修复前，下面这几条全是 nil —— 这就是用户看到的「排序变回默认」
    local st = plugin:readState()
    ok(st ~= nil, "状态文件应仍可读")
    eq(st.sort_key, "size", "读书后排序键必须还在（整表覆盖回归的第一个失败点）")
    eq(st.sort_descending, true, "读书后方向必须还在")
    eq(st.sort_folders_first, false, "读书后目录优先必须还在（false 不是「没有」）")
    -- 三个键都要「存在」，而不只是值碰巧等于默认值
    local present = 0
    for _, name in ipairs({ "sort_key", "sort_descending", "sort_folders_first" }) do
        if st[name] ~= nil then present = present + 1 end
    end
    eq(present, 3, "三个排序键都应存在于状态表里（缺一个都算回归）")
    -- 同一个动作也不该顺手抹掉 saveState 自己负责的键
    eq(st.last_server_idx, idx, "读书后服务器索引应仍写入")
    eq(st.last_paths and st.last_paths[server.address], "books",
        "读书后应记住最后浏览目录")
    eq(plugin.ui.opened, "/tmp/wdr_ui_test_data/open/books_b.txt",
        "仍应真的把文件交给 KOReader 打开（修复不能靠「不调 saveState」蒙过去）")
end)

case("排序持久化 A3：连读 3 本书，排序每次都在", function()
    local plugin = newStatePlugin()
    local idx, server = addTestServer("排序持久化连读")
    plugin.getClientFor = function() return fakeClientFor(persistFixture()) end
    Session.last_server_idx = idx
    plugin:saveSortSettings("created", true, true)

    for read_idx = 1, 3 do
        local local_path = "/tmp/wdr_ui_test_data/open/books_b" .. read_idx .. ".txt"
        plugin:openRemoteFile(server, {
            name = "b" .. read_idx .. ".txt", is_file = true,
            remote_path = "books/b" .. read_idx .. ".txt",
        }, local_path)

        local st = plugin:readState()
        local label = string.format("第 %d 次读书后", read_idx)
        eq(st and st.sort_key, "created", label .. "排序键应仍是 created")
        eq(st and st.sort_descending, true, label .. "方向应仍是降序")
        eq(st and st.sort_folders_first, true, label .. "目录优先应仍是开")
        -- 顺带证明 local_map 仍在持续更新（修复不是靠「什么都不写」换来的）
        local mapped = Session.getRemoteByLocalPath(local_path)
        ok(mapped ~= nil, label .. "应登记本地->远程映射")
        eq(mapped and mapped.remote_path, "books/b" .. read_idx .. ".txt",
            label .. "映射的远程路径应正确")
    end
end)

case("排序持久化 A4：走真实 UI 链路（browser:setSort → on_sort_changed → 落盘）", function()
    local plugin = newStatePlugin()
    local idx, server = addTestServer("排序持久化链路")
    plugin.getClientFor = function() return fakeClientFor(persistFixture()) end

    plugin:openBrowserFor(idx)
    local browser = plugin.browser
    ok(browser ~= nil, "应创建 browser")
    eq(type(browser.on_sort_changed), "function", "openBrowserFor 应接上回写状态的回调")
    eq(browser.sort_key, "name", "没有状态文件时排序应是默认值")
    eq(plugin:readSetting("sort_key"), nil, "此时磁盘上还不该有排序设置")

    -- 用户在排序对话框里选了「创建时间 降序」（与 main.lua:openBrowserFor 同一条链路）
    browser:setSort("created", true, true)
    eq(plugin:readSetting("sort_key"), "created", "setSort 应经回调写进状态文件")
    eq(plugin:readSetting("sort_descending"), true, "方向应写进状态文件")
    eq(plugin:readSetting("sort_folders_first"), true, "目录优先应写进状态文件")

    -- 紧接着点开一本书（会 saveState），UI 链路写进去的排序不能被顺手抹掉
    plugin:openRemoteFile(server, {
        name = "a.txt", is_file = true, remote_path = "books/a.txt",
    }, "/tmp/wdr_ui_test_data/open/books_a.txt")
    eq(plugin:readSetting("sort_key"), "created", "读书后 UI 链路写入的排序键应仍在")
    eq(plugin:readSetting("sort_descending"), true, "读书后方向应仍在")

    -- 合并写不能把旧值锁死：再次切换排序必须能覆盖
    browser:setSort("modified", false, false)
    eq(plugin:readSetting("sort_key"), "modified", "再次切换应覆盖排序键")
    eq(plugin:readSetting("sort_descending"), false, "再次切换应覆盖方向")
    eq(plugin:readSetting("sort_folders_first"), false, "再次切换应覆盖目录优先")
end)

case("排序持久化 B：重启后恢复排序，且列表真的按该排序排列", function()
    local plugin = newStatePlugin()
    local idx, server = addTestServer("排序持久化重启")
    plugin.getClientFor = function() return fakeClientFor(persistFixture()) end

    -- 用户：进浏览界面 → 切「大小 降序 + 目录不优先」→ 点开一本书
    plugin:openBrowserFor(idx)
    plugin.browser:setSort("size", true, false)
    eq(plugin:readSetting("sort_key"), "size", "前置：排序已落盘")
    plugin:openRemoteFile(server, {
        name = "a.txt", is_file = true, remote_path = "books/a.txt",
    }, "/tmp/wdr_ui_test_data/open/books_a.txt")

    -- 重启：模块级 Session 清空 + 新建实例（init 里从磁盘 loadState）
    local plugin2 = restartStatePlugin()
    eq(Session.last_server_idx, idx, "重启后应恢复上次的服务器索引")
    eq(Session.getLastPath(server.address), "books", "重启后应恢复上次浏览目录")

    plugin2.getClientFor = function() return fakeClientFor(persistFixture()) end
    plugin2:openBrowserFor(idx)
    local browser = plugin2.browser
    ok(browser ~= nil, "应重新创建 browser")

    eq(browser.sort_key, "size", "重启后应恢复排序键（修复前会回到 name）")
    eq(browser.sort_descending, true, "重启后应恢复降序（修复前会回到升序）")
    eq(browser.sort_folders_first, false, "重启后应恢复目录优先=关")

    -- 恢复的不只是三个字段，列表顺序也必须真的按它排
    eq(browser.item_table[1].is_go_up, true, "books 目录里首行应是「../」")
    eq(namesOf(browser.item_table), "..,d.txt,c.txt,b.txt,a.txt,sub",
        "应真的按「大小降序 + 目录不优先」排列")
    eq(browser.item_table[2].name, "d.txt", "最大的文件应紧跟导航行")
    ok(indexOfName(browser.item_table, "d.txt") < indexOfName(browser.item_table, "a.txt"),
        "size 降序：d.txt 应在 a.txt 之前（按名称升序时顺序相反，可区分）")
    eq(browser.item_table[#browser.item_table].name, "sub",
        "目录不优先时 sub 应落到最后（size 降序里它没有大小）")
    contains(browser:getSortSummary(), "大小", "副标题应显示恢复后的排序方式")
    contains(browser:getSortSummary(), "↓", "副标题应显示降序箭头")
end)

case("排序持久化 C：saveState 与 saveSortSettings 互不吞掉对方的键", function()
    local plugin = newStatePlugin()
    local idx, server = addTestServer("排序持久化键集")
    plugin.getClientFor = function() return fakeClientFor(persistFixture()) end

    plugin:saveSortSettings("size", true, false)
    Session.last_server_idx = idx
    Session.setLastPath(server.address, "books")
    Session.setCurrent(server, "books/a.txt", "/tmp/wdr_ui_test_data/open/map.txt",
        Progress:getKey(server, "books/a.txt"))

    local before = plugin:readState()
    ok(before ~= nil, "前置：应有状态")
    eq(before.sort_key, "size", "前置：排序键已写入")

    -- 方向 1：saveState 不能丢 sort_*
    plugin:saveState()
    local after = plugin:readState()
    eq(after.sort_key, "size", "saveState 后 sort_key 仍在")
    eq(after.sort_descending, true, "saveState 后 sort_descending 仍在")
    eq(after.sort_folders_first, false, "saveState 后 sort_folders_first 仍在")

    -- 方向 2：saveSortSettings 也不能丢 saveState 负责的键
    plugin:saveSortSettings("name_natural", false, true)
    local again = plugin:readState()
    eq(again.last_server_idx, idx, "saveSortSettings 后 last_server_idx 仍在")
    eq(again.last_paths and again.last_paths[server.address], "books",
        "saveSortSettings 后 last_paths 仍在")
    ok(type(again.local_map) == "table", "saveSortSettings 后 local_map 仍在")
    eq(again.local_map["/tmp/wdr_ui_test_data/open/map.txt"],
        server.address .. "\t" .. (server.name or "") .. "\tbooks/a.txt",
        "local_map 的编码格式应保持 address\\tname\\tremote_path")
    eq(again.sort_key, "name_natural", "saveSortSettings 应写入新排序键")
    eq(again.sort_folders_first, true, "saveSortSettings 应写入新目录优先值")
end)

case("排序持久化 C：Session 里没有值时，nil 不得覆盖磁盘上已有的键", function()
    local plugin = newStatePlugin()
    local idx, server = addTestServer("排序持久化nil")
    plugin:writeState({
        last_server_idx = idx,
        last_paths = { [server.address] = "papers" },
        sort_key = "size",
        sort_descending = true,
        sort_folders_first = false,
    })
    -- 模拟某条调用路径上 Session 还没初始化：last_server_idx / last_paths 都是 nil
    Session.reset()
    Session.last_paths = nil
    eq(Session.last_server_idx, nil, "前置：内存里没有服务器索引")
    eq(Session.last_paths, nil, "前置：内存里没有浏览位置")

    plugin:saveState()

    local st = plugin:readState()
    eq(st.last_server_idx, idx, "nil 不应把磁盘上已有的 last_server_idx 删掉")
    eq(st.last_paths and st.last_paths[server.address], "papers",
        "nil 不应把磁盘上已有的 last_paths 删掉")
    eq(st.sort_key, "size", "排序键仍在")
    eq(st.sort_descending, true, "方向仍在")
    eq(st.sort_folders_first, false, "目录优先仍在")
    -- local_map 是「本次会话的真实快照」，允许被覆盖成空表，但不能变成 nil
    ok(type(st.local_map) == "table", "local_map 应仍是表（不是 nil）")
end)

case("排序持久化 D：磁盘上没有状态文件时 saveState 不崩且能创建", function()
    local plugin, Main = newStatePlugin()
    local path = Main.getStatePath(Main)
    eq(readStateRaw(path), nil, "前置：状态文件不存在")
    Session.reset()
    Session.last_server_idx = nil
    Session.last_paths = nil

    local okk, err = pcall(function() plugin:saveState() end)
    ok(okk, "没有状态文件时 saveState 不应抛错：" .. tostring(err))
    ok(readStateRaw(path) ~= nil, "应创建出状态文件")
    local st = plugin:readState()
    ok(st ~= nil, "新状态应可读回")
    ok(type(st.local_map) == "table", "应写入 local_map（至少是空表）")
    eq(st.sort_key, nil, "没有排序设置时不应凭空造出一个假值")
end)

case("排序持久化 D：状态文件损坏时 readState 返回 nil，saveState 能重建", function()
    local plugin, Main = newStatePlugin()
    local path = Main.getStatePath(Main)

    local function writeRaw(content)
        local fh = assert(io.open(path, "w"))
        fh:write(content)
        fh:close()
    end

    -- a) 语法错误（loadfile 直接失败）
    writeRaw("return { this is not valid lua")
    eq(plugin:readState(), nil, "语法错误的状态文件应读出 nil")
    local okk, err = pcall(function() plugin:saveState() end)
    ok(okk, "损坏文件时 saveState 不应抛错：" .. tostring(err))
    local st = plugin:readState()
    ok(st ~= nil, "saveState 应重建出可读的状态")
    eq(st.sort_key, nil, "重建的状态不应含伪造的排序键")

    -- b) 语法正确但运行时报错（loadfile 成功、pcall 失败）
    writeRaw('error("state file is broken")')
    eq(plugin:readState(), nil, "运行时报错的状态文件应读出 nil")
    ok(pcall(function() plugin:saveState() end), "运行时报错时 saveState 也不应抛错")

    -- c) 读出来不是表
    writeRaw("return 42")
    eq(plugin:readState(), nil, "非表内容应读出 nil")
    ok(pcall(function() plugin:saveState() end), "非表内容时 saveState 也不应抛错")

    -- d) 空文件
    writeRaw("")
    eq(plugin:readState(), nil, "空文件应读出 nil")
    ok(pcall(function() plugin:saveState() end), "空文件时 saveState 也不应抛错")
    ok(plugin:readState() ~= nil, "最终仍应留下可读的状态")
end)

case("排序持久化 E：KOReader 的 onFlushSettings 也不得抹掉排序", function()
    local plugin = newStatePlugin()
    local idx, server = addTestServer("排序持久化flush")
    plugin.getClientFor = function() return fakeClientFor(persistFixture()) end
    plugin:saveSortSettings("modified", true, true)
    Session.last_server_idx = idx
    Session.setLastPath(server.address, "books")

    -- onFlushSettings 是 KOReader 退出/切书时的高频入口，它内部也调 saveState
    local okk, err = pcall(function() plugin:onFlushSettings() end)
    ok(okk, "onFlushSettings 不应抛错：" .. tostring(err))
    eq(plugin:readSetting("sort_key"), "modified", "flush 后排序键仍在")
    eq(plugin:readSetting("sort_descending"), true, "flush 后方向仍在")
    eq(plugin:readSetting("sort_folders_first"), true, "flush 后目录优先仍在")
    eq(plugin:readSetting("last_server_idx"), idx, "flush 后服务器索引仍在")
end)

--------------------------------------------------------------------------------
-- 用例：列表行首图标（回归：emoji 图标在 KOReader 字体链里没有字形 → 方框+问号）
--------------------------------------------------------------------------------
-- 背景见 TECHNICAL.md「行首图标为什么不用 emoji」：
-- KOReader 界面文字只走它自带的回退字体链（Font.fallbacks），📁(U+1F4C1)/
-- 📄(U+1F4C4) 在这些字体里没有字形，设备上显示成 .notdef（方框+问号）。
-- 现在改用 NotoSansCJKsc 里确实有字形的几何符号：▣(U+25A3) / ▤(U+25A4)。

--- 解码 UTF-8 字符串为码位数组（Lua 5.1 没有 utf8 库）
local function codepoints(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local cp, len
        if c < 0x80 then
            cp, len = c, 1
        elseif c < 0xE0 then
            cp, len = c % 0x20, 2
        elseif c < 0xF0 then
            cp, len = c % 0x10, 3
        elseif c < 0xF8 then
            cp, len = c % 0x08, 4
        else
            cp, len = c % 0x04, 5
        end
        for k = 1, len - 1 do
            local cc = s:byte(i + k)
            if not cc then break end
            cp = cp * 0x40 + (cc % 0x40)
        end
        out[#out + 1] = cp
        i = i + len
    end
    return out
end

--- 递归收集插件目录下的 .lua 文件（相对当前工作目录）。lfs 不可用时退回固定清单。
local function pluginLuaFiles()
    local files = {}
    local ok_lfs, lfs = pcall(require, "lfs")
    if ok_lfs then
        local function walk(dir)
            local ok_dir, iter, state = pcall(lfs.dir, dir)
            if not ok_dir then return end
            for entry in iter, state do
                if entry ~= "." and entry ~= ".." then
                    local full = dir .. "/" .. entry
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        walk(full)
                    elseif mode == "file" and entry:sub(-4) == ".lua" then
                        files[#files + 1] = full
                    end
                end
            end
        end
        walk("webdavreader.koplugin")
    end
    if #files == 0 then
        -- 兜底清单：lfs 加载失败时至少覆盖关键文件
        for _, name in ipairs({
            "main.lua", "_meta.lua",
            "wdr/browser.lua", "wdr/sort.lua", "wdr/history.lua", "wdr/cache.lua",
            "wdr/config.lua", "wdr/progress.lua", "wdr/store.lua", "wdr/session.lua",
            "wdr/manager.lua", "wdr/webdav.lua", "wdr/json.lua",
        }) do
            files[#files + 1] = "webdavreader.koplugin/" .. name
        end
    end
    return files
end

local function readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    return content
end

case("行首图标：目录用 ▣(U+25A3)、文件用 ▤(U+25A4)", function()
    local Browser = dofile("webdavreader.koplugin/wdr/browser.lua")

    -- 图标以字段形式暴露，便于统一调整/断言
    eq(Browser.ICON_FOLDER, "▣", "目录图标应是 ▣")
    eq(Browser.ICON_FILE, "▤", "文件图标应是 ▤")
    eq(codepoints(Browser.ICON_FOLDER)[1], 0x25A3, "目录图标码位应是 U+25A3")
    eq(codepoints(Browser.ICON_FILE)[1], 0x25A4, "文件图标码位应是 U+25A4")

    local browser = Browser:new{
        plugin = { config = Config },
        config = Config,
        progress = Progress,
        cache = Cache,
    }
    browser:init()
    browser.server_idx = 1

    local tbl = browser:buildItemTable({
        { name = "sub", is_folder = true, path = "sub" },
        { name = "三体.txt", is_folder = false, path = "三体.txt", size = 2048 },
    }, "")

    eq(#tbl, 2, "应有目录 + 文件两项")
    eq(tbl[1].is_folder, true, "前置：目录排第一")

    -- 目录行：行首必须是 ▣ + 空格，名字原样保留
    local folder_cps = codepoints(tbl[1].text)
    eq(folder_cps[1], 0x25A3, "目录行行首应是 ▣（U+25A3），实际：" .. tostring(tbl[1].text))
    eq(tbl[1].text, "▣ sub", "目录行文案")
    eq(folder_cps[2], 0x20, "图标与名称之间应有一个空格")

    -- 文件行：行首必须是 ▤ + 空格
    local file_cps = codepoints(tbl[2].text)
    eq(file_cps[1], 0x25A4, "文件行行首应是 ▤（U+25A4），实际：" .. tostring(tbl[2].text))
    eq(tbl[2].text, "▤ 三体.txt", "文件行文案")
    eq(file_cps[2], 0x20, "图标与名称之间应有一个空格")

    -- 行首图标既不是 emoji 也不是私有区字符（那两类才会渲染成方框+问号）
    for _, cp in ipairs({ folder_cps[1], file_cps[1] }) do
        ok(cp < 0x1F000, string.format("图标不应落在 emoji 区（U+%04X）", cp))
        ok(not (cp >= 0xE000 and cp <= 0xF8FF), string.format("图标不应落在私有区（U+%04X）", cp))
    end
end)

case("源码守卫：插件内不得使用 emoji / Nerd Font 私有区字符当图标", function()
    local files = pluginLuaFiles()
    ok(#files >= 10, "应能枚举到插件源码文件，实际找到 " .. #files .. " 个")

    local bad = {}
    for _, path in ipairs(files) do
        local content = readFile(path)
        if content then
            for _, cp in ipairs(codepoints(content)) do
                -- U+1F000 以上：emoji / 星形平面；U+E000–U+F8FF：Nerd Font 私有区
                if cp >= 0x1F000 or (cp >= 0xE000 and cp <= 0xF8FF) then
                    bad[#bad + 1] = string.format("%s 含 U+%04X", path, cp)
                end
            end
        end
    end
    ok(#bad == 0,
        "KOReader 自带字体里没有这些字形，会显示成方框+问号：\n      " .. table.concat(bad, "\n      "))
end)

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------

os.execute("rm -rf /tmp/wdr_ui_test_data")

print("")
print(string.rep("-", 62))
if fail_count > 0 then
    print(string.format("失败用例：%d 个", #failures))
    for _, f in ipairs(failures) do
        print("  ✗ " .. f)
    end
end
print(string.format("结果：%d 通过, %d 失败, 共 %d 个断言",
    pass_count, fail_count, pass_count + fail_count))
print(string.rep("-", 62))

os.exit(fail_count == 0 and 0 or 1)
