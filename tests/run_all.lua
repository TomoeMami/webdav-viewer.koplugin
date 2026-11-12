--[[--
测试运行器：统一设置 package.path / package.cpath / 桩件，然后逐个加载测试文件。

用法：
    cd /home/riko/koreader-plugin
    ./tools/lua tests/run_all.lua             # 跑全部
    ./tools/lua tests/run_all.lua json store  # 只跑指定名（去掉 test_ 前缀）
--]]--

local this_file = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this_file:match("^(.*)/[^/]+$") or "."
-- root 是 tests 的父目录；当 tests_dir 没有父目录时（以相对路径调用），root 为 "."
local root = tests_dir:match("^(.*)/[^/]+$") or "."
if root == "" then root = "/" end

package.path = table.concat({
    root .. "/tests/?.lua",
    root .. "/webdavreader.koplugin/?.lua",
    package.path,
}, ";")

package.cpath = table.concat({
    root .. "/tools/?.so",
    package.cpath,
}, ";")

-- 测试环境的数据目录（每次清空）
local test_data = os.getenv("WDR_TEST_DATA_DIR") or "/tmp/wdr_test_data"
os.execute("rm -rf '" .. test_data .. "'")
os.execute("mkdir -p '" .. test_data .. "/settings' '" .. test_data .. "/data'")

require("stubs").install()

local requested = {}
for i = 1, #arg do
    requested[arg[i]] = true
end

-- ---------------------------------------------------------------------------
-- 断言收集器
-- ---------------------------------------------------------------------------

local State = {
    suite = nil,
    total = 0,
    passed = 0,
    failed = 0,
    failures = {},
}

local T = {}

local function fail(msg, level)
    error(msg, (level or 1) + 1)
end

function T.eq(actual, expected, msg)
    if actual ~= expected then
        fail(string.format("%s: 期望 %s，实际 %s",
            msg or "eq", tostring(expected), tostring(actual)), 2)
    end
end

function T.neq(actual, unexpected, msg)
    if actual == unexpected then
        fail(string.format("%s: 不应等于 %s", msg or "neq", tostring(unexpected)), 2)
    end
end

function T.near(actual, expected, eps, msg)
    eps = eps or 1e-9
    if type(actual) ~= "number" then
        fail(string.format("%s: 期望数字，实际 %s", msg or "near", tostring(actual)), 2)
    end
    if math.abs(actual - expected) > eps then
        fail(string.format("%s: 期望 ≈%s，实际 %s", msg or "near", tostring(expected), tostring(actual)), 2)
    end
end

function T.ok(v, msg)
    if not v then
        fail((msg or "ok") .. ": 期望为真，实际 " .. tostring(v), 2)
    end
end

function T.falsy(v, msg)
    if v then
        fail((msg or "falsy") .. ": 期望为假，实际 " .. tostring(v), 2)
    end
end

function T.contains(haystack, needle, msg)
    if type(haystack) ~= "string" then
        fail(string.format("%s: 期望字符串，实际 %s", msg or "contains", type(haystack)), 2)
    end
    if not haystack:find(needle, 1, true) then
        fail(string.format("%s: %q 中未找到 %q", msg or "contains", haystack, needle), 2)
    end
end

function T.not_contains(haystack, needle, msg)
    if type(haystack) == "string" and haystack:find(needle, 1, true) then
        fail(string.format("%s: %q 中不应出现 %q", msg or "not_contains", haystack, needle), 2)
    end
end

function T.is_table(v, msg)
    if type(v) ~= "table" then
        fail((msg or "is_table") .. ": 期望 table，实际 " .. type(v), 2)
    end
end

function T.is_nil(v, msg)
    if v ~= nil then
        fail((msg or "is_nil") .. ": 期望 nil，实际 " .. tostring(v), 2)
    end
end

function T.raises(fn, msg)
    local ok = pcall(fn)
    if ok then
        fail((msg or "raises") .. ": 期望抛出错误，但没有", 2)
    end
end

function T.test(name, fn)
    State.total = State.total + 1
    local ok, err = pcall(fn)
    if ok then
        State.passed = State.passed + 1
        io.write("  PASS  ", name, "\n")
    else
        State.failed = State.failed + 1
        io.write("  FAIL  ", name, "  →  ", tostring(err), "\n")
        table.insert(State.failures, {
            suite = State.suite,
            name = name,
            detail = err,
        })
    end
end

-- ---------------------------------------------------------------------------
-- 运行
-- ---------------------------------------------------------------------------

local suites = {
    "test_json",
    "test_store",
    "test_config",
    "test_cache",
    "test_progress",
    "test_sort",
    "test_history",
    "test_shadow",
    "test_webdav",
    "test_manager",
    "test_ui",
    "test_integration",
}

local ran, skipped = 0, 0
for _, name in ipairs(suites) do
    local short = name:gsub("^test_", "")
    if next(requested) == nil or requested[short] or requested[name] then
        local path = root .. "/tests/" .. name .. ".lua"
        local fh = io.open(path, "r")
        if not fh then
            skipped = skipped + 1
            io.write(string.format("\n  SKIP  %s（文件不存在）\n", name))
        else
            local head = fh:read(400) or ""
            fh:close()
            -- 自运行型测试（自己 os.exit）用子进程跑，避免终止主进程
            if head:find("@selfrun", 1, true) then
                ran = ran + 1
                io.write(string.format("\n### %s （自运行，子进程）\n", name))
                local cmd = string.format("cd %q && ./tools/lua tests/%s.lua 2>&1; echo __WDR_EXIT__$?", root, name)
                local pipe = io.popen(cmd)
                local output = pipe and pipe:read("*all") or ""
                local ok_exit = pipe and pipe:close()
                -- 解析「结果：N 通过, M 失败」这类汇总行
                local np = tonumber(output:match("(%d+)%s*通过")) or 0
                local nf = tonumber(output:match("(%d+)%s*失败")) or 0
                State.total = State.total + np + nf
                State.passed = State.passed + np
                State.failed = State.failed + nf
                if ok_exit and nf == 0 then
                    io.write(string.format("  子进程全部通过（%d 断言）\n", np))
                else
                    io.write(output)
                    if nf == 0 then
                        -- 解析不出计数但退出码非 0：按一个失败计
                        State.total = State.total + 1
                        State.failed = State.failed + 1
                        table.insert(State.failures, {
                            suite = name,
                            name = "(子进程)",
                            detail = "退出码非 0，且无法解析断言数",
                        })
                    end
                end
            else
                ran = ran + 1
                local ok, err = pcall(function()
                    local suite = dofile(path)
                    if type(suite) == "table" and suite.run then
                        -- 第二个参数是「临时工作目录」，放在 /tmp 下，避免污染仓库
                        suite.run(T, "/tmp/wdr_suite_work")
                    else
                        error("测试文件必须返回 { run = function(T, root) ... end }，或在文件末尾加 -- @selfrun 标记")
                    end
                end)
                if not ok then
                    State.total = State.total + 1
                    State.failed = State.failed + 1
                    table.insert(State.failures, {
                        suite = name,
                        name = "(套件加载)",
                        detail = err,
                    })
                    io.write(string.format("\n  FAIL  套件 %s 加载失败: %s\n", name, tostring(err)))
                end
            end
        end
    end
end

io.write("\n" .. string.rep("=", 64) .. "\n")
io.write(string.format("总计: %d 个断言，通过 %d，失败 %d（运行套件 %d，跳过 %d）\n",
    State.total, State.passed, State.failed, ran, skipped))
if State.failed > 0 then
    io.write("\n失败清单：\n")
    for _, f in ipairs(State.failures) do
        io.write(string.format("  - [%s] %s\n      %s\n", f.suite or "-", f.name, tostring(f.detail)))
    end
    io.write(string.rep("=", 64) .. "\n")
    os.exit(1)
end
io.write(string.rep("=", 64) .. "\n")
io.write("全部通过\n")
os.exit(0)
