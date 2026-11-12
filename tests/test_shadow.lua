-- @selfrun 自包含运行（内部 os.exit），由 run_all.lua 以子进程方式调用
--[[--
静态检查：gettext `_` 被循环占位变量遮蔽（本项目曾因此线上崩溃）

为什么需要它：`main.lua` / `browser.lua` 等文件顶部有 `local _ = require("gettext")`。
若在同一作用域写成 `for _, x in ipairs(...)`，`_` 会被遮蔽成 ipairs 的索引数字；
之后再（尤其在被延迟执行的闭包里）调用 `_("...")` 就会抛
    attempt to call local '_' (a number value)

这类 bug 单测很容易漏掉——闭包只在用户点击时才执行。本项目实际踩过三次：
  * `main.lua:showProgressList`   → 点「阅读进度记录」任意条目必崩
  * `main.lua:showMoveHistory`    → 点「移动位置记录」任意条目必崩
  * `browser.lua:enterPath` 回退分支 → 首次进目录失败需回退时整个界面崩

规则：只要文件里存在 `local _ = ...` 或 `require("gettext")`，就不允许出现
`for _, ...` 这种把 `_` 当循环占位变量的写法。没有引入 gettext 的文件
（如 cache.lua / json.lua）不受限制——那里 `_` 只是普通变量，无害。

@module tests.test_shadow
--]]--

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

local function case(name, fn)
    current_case = name
    local okk, err = pcall(fn)
    if not okk then
        fail_count = fail_count + 1
        failures[#failures + 1] = string.format("[%s] 抛出异常: %s", name, tostring(err))
    end
end

local function readAll(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local content = fh:read("*all")
    fh:close()
    return content
end

--- 收集生产代码文件（插件本体，不含 tests/）
local files = {}
local function addFile(p)
    local fh = io.open(p, "r")
    if fh then
        fh:close()
        files[#files + 1] = p
    end
end

addFile("webdavreader.koplugin/main.lua")
addFile("webdavreader.koplugin/_meta.lua")
local pipe = io.popen("ls webdavreader.koplugin/wdr/*.lua 2>/dev/null")
if pipe then
    for line in pipe:lines() do
        files[#files + 1] = line
    end
    pipe:close()
end

--- 扫描一个文件，返回违规行列表
-- @return table array of { line=, code= }，另返回「该文件是否使用 gettext」
local function scanFile(path)
    local content = readAll(path)
    if not content then return {}, false end

    local uses_gettext = content:find('require("gettext")', 1, true) ~= nil
        or content:find("local _ =", 1, true) ~= nil
        or content:find("local _=", 1, true) ~= nil
    if not uses_gettext then return {}, false end

    local found = {}
    local lineno = 0
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        -- 去掉行内注释再判断，避免把说明文字误判成代码
        local code = line:gsub("%-%-.*$", "")
        if code:match("for%s+_%s*,?") or code:match("for%s+_%s+in%s") then
            found[#found + 1] = { line = lineno, code = line:match("^%s*(.-)%s*$") }
        end
    end
    return found, true
end

-- ---------------------------------------------------------------------------
-- 用例
-- ---------------------------------------------------------------------------

case("能收集到生产代码文件", function()
    ok(#files > 0, "应至少收集到一个 .lua 文件")
    -- 至少要能看到 main.lua 与 browser.lua，否则说明路径不对、检查形同虚设
    local joined = table.concat(files, "\n")
    ok(joined:find("main.lua", 1, true) ~= nil, "应包含 main.lua")
    ok(joined:find("browser.lua", 1, true) ~= nil, "应包含 browser.lua")
end)

case("所有使用 gettext 的文件都没有 `_` 被循环变量遮蔽", function()
    local violations = {}
    local checked = 0
    for _, path in ipairs(files) do
        local found, uses_gettext = scanFile(path)
        if uses_gettext then
            checked = checked + 1
            for _, v in ipairs(found) do
                violations[#violations + 1] = string.format("%s:%d  %s", path, v.line, v.code)
            end
        end
    end
    ok(checked > 0, "应检查到至少一个使用 gettext 的文件（否则规则没生效）")
    if #violations > 0 then
        failures[#failures + 1] = "发现 `_` 被循环变量遮蔽（会导致 _() 调用崩溃）：\n      "
            .. table.concat(violations, "\n      ")
            .. "\n      修复：把循环变量 `_` 改成具名变量（如 entry_idx / candidate_idx）。"
        fail_count = fail_count + 1
    else
        pass_count = pass_count + 1
    end
end)

case("扫描器本身有效：能识别违规写法", function()
    -- 自测：构造一个临时文件，确认扫描规则真的会报警（防止规则写成永远 PASS）
    local tmp = "/tmp/wdr_shadow_selftest.lua"
    local fh = io.open(tmp, "w")
    ok(fh ~= nil, "应能写临时文件")
    if fh then
        fh:write('local _ = require("gettext")\n'
            .. 'local t = {}\n'
            .. 'for _, x in ipairs(t) do\n'
            .. '  print(_("hi"))\n'
            .. 'end\n')
        fh:close()

        local found, uses = scanFile(tmp)
        ok(uses == true, "自测文件应被判定为使用 gettext")
        ok(#found == 1, "应识别出 1 处 `for _,`，实际 " .. tostring(#found))
        if #found > 0 then
            ok(found[1].line == 3, "应定位到第 3 行，实际 " .. tostring(found[1].line))
        end
        os.remove(tmp)
    end
end)

case("扫描器不误报：没有 gettext 的文件允许 `for _,`", function()
    local tmp = "/tmp/wdr_shadow_selftest2.lua"
    local fh = io.open(tmp, "w")
    ok(fh ~= nil, "应能写临时文件")
    if fh then
        fh:write('local t = {1,2}\n'
            .. 'for _, x in ipairs(t) do print(x) end\n')
        fh:close()

        local found, uses = scanFile(tmp)
        ok(uses == false, "没有 gettext 的文件不应被判定为使用 _()")
        ok(#found == 0, "不应报违规，实际 " .. tostring(#found))
        os.remove(tmp)
    end
end)

case("扫描器不误报：注释里的 `for _,` 不算违规", function()
    local tmp = "/tmp/wdr_shadow_selftest3.lua"
    local fh = io.open(tmp, "w")
    ok(fh ~= nil, "应能写临时文件")
    if fh then
        fh:write('local _ = require("gettext")\n'
            .. '-- 不要写成 for _, x in ipairs(t) 这样\n'
            .. 'print(_("hi"))\n')
        fh:close()

        local found = scanFile(tmp)
        ok(#found == 0, "注释里的写法不应算违规，实际 " .. tostring(#found))
        os.remove(tmp)
    end
end)

case("扫描器不误报：具名循环变量不算违规", function()
    local tmp = "/tmp/wdr_shadow_selftest4.lua"
    local fh = io.open(tmp, "w")
    ok(fh ~= nil, "应能写临时文件")
    if fh then
        fh:write('local _ = require("gettext")\n'
            .. 'local t = {1}\n'
            .. 'for idx, x in ipairs(t) do print(_("hi"), idx, x) end\n'
            .. 'for key_idx, k in ipairs(t) do print(k) end\n')
        fh:close()

        local found = scanFile(tmp)
        ok(#found == 0, "具名变量不应报违规，实际 " .. tostring(#found))
        os.remove(tmp)
    end
end)

-- ---------------------------------------------------------------------------
-- 汇总
-- ---------------------------------------------------------------------------

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
