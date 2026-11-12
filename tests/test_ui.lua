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
    eq(#item.sub_item_table, 4, "应有 4 个子项")
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
