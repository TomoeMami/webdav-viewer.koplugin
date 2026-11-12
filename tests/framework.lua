--[[--
极简测试框架（纯 Lua 5.1，无外部依赖）

用法：
    local t = require("framework")
    t.test("用例名", function() t.eq(1, 1, "描述") end)
    t.run()
--]]--

local T = {
    passed = 0,
    failed = 0,
    errors = {},
    current = nil,
    total = 0,
}

local function record(ok, name, detail)
    T.total = T.total + 1
    if ok then
        T.passed = T.passed + 1
        io.write("  PASS  ", name, "\n")
    else
        T.failed = T.failed + 1
        io.write("  FAIL  ", name, "  ->  ", tostring(detail), "\n")
        table.insert(T.errors, { name = name, detail = detail })
    end
end

function T.test(name, fn)
    -- 每个用例独立 pcall，避免一个崩溃带走全部
    local ok, err = pcall(fn)
    if not ok then
        record(false, name, err)
    else
        record(true, name)
    end
end

function T.eq(actual, expected, msg)
    msg = msg or "eq"
    if actual ~= expected then
        error(string.format("%s: 期望 %s，实际 %s", msg, tostring(expected), tostring(actual)), 2)
    end
end

function T.near(actual, expected, eps, msg)
    msg = msg or "near"
    eps = eps or 1e-9
    if type(actual) ~= "number" then
        error(string.format("%s: 期望数字，实际 %s", msg, tostring(actual)), 2)
    end
    if math.abs(actual - expected) > eps then
        error(string.format("%s: 期望 ≈%s，实际 %s", msg, tostring(expected), tostring(actual)), 2)
    end
end

function T.ok(v, msg)
    msg = msg or "ok"
    if not v then
        error(msg .. ": 期望为真，实际 " .. tostring(v), 2)
    end
end

function T.falsy(v, msg)
    msg = msg or "falsy"
    if v then
        error(msg .. ": 期望为假，实际 " .. tostring(v), 2)
    end
end

function T.contains(haystack, needle, msg)
    msg = msg or "contains"
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(string.format("%s: %s 中未找到 %s", msg, tostring(haystack), tostring(needle)), 2)
    end
end

function T.is_table(v, msg)
    msg = msg or "is_table"
    if type(v) ~= "table" then
        error(msg .. ": 期望 table，实际 " .. type(v), 2)
    end
end

--- 期望 fn 抛出错误
function T.raises(fn, msg)
    msg = msg or "raises"
    local ok = pcall(fn)
    if ok then
        error(msg .. ": 期望抛出错误，但没有", 2)
    end
end

--- 汇总并决定退出码
function T.run(suite_name)
    io.write("\n" .. string.rep("-", 60) .. "\n")
    io.write(string.format("%s: %d 个用例，通过 %d，失败 %d\n",
        suite_name or "suite", T.total, T.passed, T.failed))
    if T.failed > 0 then
        io.write("\n失败详情：\n")
        for _, e in ipairs(T.errors) do
            io.write("  - ", e.name, "\n      ", tostring(e.detail), "\n")
        end
        io.write(string.rep("-", 60) .. "\n")
        os.exit(1)
    end
    io.write(string.rep("-", 60) .. "\n")
end

--- 把 package.path 指到插件目录
function T.setupPath()
    local this_dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
    local root = this_dir:match("^(.*)/[^/]+$") or this_dir
    package.path = root .. "/webdavreader.koplugin/?.lua;" .. package.path
    return root
end

return T
