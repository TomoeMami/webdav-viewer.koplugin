--[[--
在桌面 Lua 环境下为 KOReader 内部模块提供桩件。

被测模块会 require 这些 KOReader 模块，桌面上没有它们，
这里用 package.preload 提供最小可用实现（仅覆盖本插件用到的部分）。
--]]--

local Stubs = {}

--- 安装全部桩件。重复调用安全。
function Stubs.install()
    if Stubs._installed then return Stubs end

    -- gettext：与 KOReader 一样，是一个「可调用 table」（靠 __call 元方法）
    package.preload["gettext"] = function()
        local gettext = {
            translation = {},
            context = {},
            current_lang = "C",
            wrapUntranslated = function(s) return s end,
        }
        local mt = {
            __call = function(_, msgid) return msgid end,
        }
        mt.__index = gettext
        gettext.ngettext = function(singular, plural, n)
            return (n == 1) and singular or plural
        end
        gettext.npgettext = function(_, singular, plural, n)
            return (n == 1) and singular or plural
        end
        gettext.pgettext = function(_, msgid) return msgid end
        gettext.changeLang = function() end
        return setmetatable(gettext, mt)
    end

    -- logger
    package.preload["logger"] = function()
        local lg = { messages = {} }
        local function make(level)
            return function(...)
                local parts = {}
                for i = 1, select("#", ...) do
                    parts[i] = tostring((select(i, ...)))
                end
                table.insert(lg.messages, level .. ": " .. table.concat(parts, " "))
            end
        end
        lg.dbg = make("dbg")
        lg.info = make("info")
        lg.warn = make("warn")
        lg.err = make("err")
        return lg
    end

    -- ffi/util：只提供 basename / joinPath / dirname / template / strcoll
    package.preload["ffi/util"] = function()
        local M = {}
        function M.basename(p)
            if not p then return "" end
            return (tostring(p):gsub("/+$", "")):match("([^/]*)$") or ""
        end
        function M.dirname(p)
            if not p then return "." end
            local d = tostring(p):match("^(.*)/[^/]*$")
            return d or "."
        end
        function M.joinPath(...)
            local parts = { ... }
            local out = {}
            for _, p in ipairs(parts) do
                if p and p ~= "" then
                    table.insert(out, tostring(p):gsub("^/+", ""):gsub("/+$", ""))
                end
            end
            return table.concat(out, "/")
        end
        function M.template(str, ...)
            local args = { ... }
            return (str:gsub("^%$(%d+)$", function(d) return tostring(args[tonumber(d)] or "") end)
                       :gsub("%$(%d+)", function(d) return tostring(args[tonumber(d)] or "") end))
        end
        function M.strcoll(a, b) return a < b end
        function M.realpath(p) return p end
        function M.copyFile(src, dst)
            local fi = io.open(src, "rb")
            if not fi then return false end
            local fo = io.open(dst, "wb")
            if not fo then fi:close() return false end
            fo:write(fi:read("*all"))
            fi:close()
            fo:close()
            return true
        end
        function M.getFileNameSuffix(p)
            return tostring(p):match("%.([%w]+)$")
        end
        return M
    end

    -- ffi/sha2：用纯 Lua 的 md5 实现替代（保证 store.shortHash 可用）
    package.preload["ffi/sha2"] = function()
        local M = {}
        function M.md5(s)
            -- 简化：用 djb2 + 长度生成 32 位十六进制（单测不验证密码学正确性，
            -- 只要求确定性、分布均匀、长度足够）
            local h1, h2 = 5381, 52711
            for i = 1, #s do
                local b = s:byte(i)
                h1 = (h1 * 33 + b) % 4294967296
                h2 = (h2 * 31 + b * 7) % 4294967296
            end
            return string.format("%08x%08x%08x%08x", h1, h2, (#s * 2654435761) % 4294967296, (h1 + h2) % 4294967296)
        end
        function M.sha256(s) return M.md5(s) .. M.md5(s .. "x") end
        return M
    end

    -- util：只提供本插件用到的部分
    package.preload["util"] = function()
        local M = {}
        function M.trim(s)
            local from = s:match("^%s*()")
            return from > #s and "" or s:match(".*%S", from)
        end
        -- 与 KOReader 的 util.urlEncode 语义一致：
        -- 保留字母数字与 -._~ 以及 preserve_chars 中列出的字符，其余编码为 %XX。
        function M.urlEncode(url, preserve_chars)
            if url == nil then return nil end
            preserve_chars = preserve_chars or ""
            local pattern_base = "^%w%-%._~"
            local pattern = string.format("([%s%s])", pattern_base, preserve_chars)
            url = url:gsub("\n", "\r\n")
            url = url:gsub("[^%w%-%._~" .. preserve_chars .. "]", function(c)
                return string.format("%%%02X", string.byte(c))
            end)
            return url
        end
        function M.urlDecode(url)
            if not url then return nil end
            return (url:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end))
        end
        function M.htmlEntitiesToUtf8(s)
            if not s then return s end
            s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
                   :gsub("&apos;", "'"):gsub("&amp;", "&")
            s = s:gsub("&#(%d+);", function(n)
                local cp = tonumber(n)
                if cp < 128 then return string.char(cp) end
                return s
            end)
            return s
        end
        function M.getFileNameSuffix(file)
            return tostring(file):match("%.([%w]+)$")
        end
        function M.splitFilePathName(file)
            local dir, name = tostring(file):match("^(.*)/([^/]*)$")
            if not dir then return "", file end
            return dir .. "/", name
        end
        function M.getFriendlySize(size)
            if not size then return "" end
            if size < 1024 then return size .. " B" end
            if size < 1024 * 1024 then return string.format("%.1f KB", size / 1024) end
            return string.format("%.1f MB", size / 1024 / 1024)
        end
        function M.tableSize(t)
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            return n
        end
        function M.stringEndsWith(str, ending)
            return ending == "" or str:sub(-#ending) == ending
        end
        function M.stringStartsWith(str, starting)
            return str:sub(1, #starting) == starting
        end
        return M
    end

    -- libs/libkoreader-lfs：转发真正的 lfs（tools/lfs.so），KOReader 的 lfs 是同一套 API
    package.preload["libs/libkoreader-lfs"] = function()
        local ok, lfs = pcall(require, "lfs")
        if ok then return lfs end
        error("测试环境缺少 lfs 模块，请确认 tools/lfs.so 存在并在 package.cpath 中")
    end

    -- datastorage：指向临时目录
    package.preload["datastorage"] = function()
        local tmp = os.getenv("WDR_TEST_DATA_DIR") or "/tmp/wdr_test_data"
        local M = {}
        function M:getSettingsDir() return tmp .. "/settings" end
        function M:getDataDir() return tmp .. "/data" end
        function M:getHistoryDir() return tmp .. "/history" end
        function M:getFullDataDir() return tmp .. "/data" end
        return M
    end

    -- luasettings：内存 + 可选文件落盘
    package.preload["luasettings"] = function()
        local LuaSettings = {}
        LuaSettings.__index = LuaSettings
        function LuaSettings:extend(o)
            return setmetatable(o or {}, LuaSettings)
        end
        function LuaSettings:open(path)
            local self = setmetatable({ file = path, data = {} }, LuaSettings)
            local fh = io.open(path, "r")
            if fh then
                local content = fh:read("*all")
                fh:close()
                local chunk = loadstring(content)
                if chunk then
                    local ok, t = pcall(chunk)
                    if ok and type(t) == "table" then self.data = t end
                end
            end
            return self
        end
        function LuaSettings:readSetting(key, default)
            local v = self.data[key]
            if v == nil then return default end
            return v
        end
        function LuaSettings:saveSetting(key, value) self.data[key] = value end
        function LuaSettings:delSetting(key) self.data[key] = nil end
        function LuaSettings:has(key) return self.data[key] ~= nil end
        function LuaSettings:isTrue(key) return self.data[key] == true end
        function LuaSettings:flush()
            if not self.file then return end
            local parts = { "return {" }
            local keys = {}
            for k in pairs(self.data) do table.insert(keys, k) end
            table.sort(keys)
            for _, k in ipairs(keys) do
                table.insert(parts, string.format("  [%q] = %s,", k, serialize(self.data[k])))
            end
            table.insert(parts, "}")
            local fh = io.open(self.file, "w")
            if fh then
                fh:write(table.concat(parts, "\n"))
                fh:close()
            end
        end
        function LuaSettings:close() self:flush() end
        return LuaSettings
    end

    Stubs._installed = true
    return Stubs
end

--- 简易序列化（供 luasettings 桩件使用）
function serialize(v, depth)
    depth = depth or 1
    if depth > 10 then return "nil" end
    local t = type(v)
    if t == "string" then return string.format("%q", v)
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif t == "nil" then return "nil"
    elseif t == "table" then
        local parts = { "{" }
        local keys = {}
        for k in pairs(v) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            table.insert(parts, string.format("[%s] = %s,", serialize(k, depth + 1), serialize(v[k], depth + 1)))
        end
        table.insert(parts, "}")
        return table.concat(parts)
    end
    return "nil"
end

_G.serialize = serialize

return Stubs
