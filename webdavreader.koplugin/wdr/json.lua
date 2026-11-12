-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
轻量 JSON 编解码器（纯 Lua 5.1，无外部依赖）

为什么不用 KOReader 自带的 `json`(cjson)：
  1. cjson 把空 table 编码成 {} 或 [] 不可控，进度文件里两种含义不同；
  2. 本插件需要在桌面 Lua 下完整单测，自带实现便于离线验证；
  3. 避免 cjson 在异常输入下抛出不可捕获的 C 层错误。

支持：object / array / string / number / boolean / null(json.null)。
编码输出为「键排序」的紧凑 JSON，便于 diff 与人工查看。

@module koplugin.webdavreader.json
--]]--

local json = {}

--- 显式 null 值（Lua 的 nil 在 table 中无法存在，用哨兵表示）。
json.null = setmetatable({}, { __tostring = function() return "json.null" end })

local escape_map = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escapeString(s)
    return (s:gsub('[%z\1-\31\\"]', function(c)
        local mapped = escape_map[c]
        if mapped then return mapped end
        return string.format("\\u%04x", c:byte())
    end))
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false
        end
        n = n + 1
    end
    -- 空表按对象处理；纯 1..n 连续整数键按数组处理
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

-- 显式标记某个 table 必须编码成数组（空数组场景）
local array_mt = { __jsontype = "array" }

--- 把一个 table 标记为「始终编码成 JSON 数组」。
function json.array(t)
    return setmetatable(t or {}, array_mt)
end

local function encodeValue(v, seen, depth)
    local tv = type(v)
    if tv == "nil" then
        return "null"
    elseif v == json.null then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return "null" -- NaN/Inf 不是合法 JSON
        end
        if v % 1 == 0 and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%.14g", v)
    elseif tv == "string" then
        return '"' .. escapeString(v) .. '"'
    elseif tv == "table" then
        if depth > 40 then
            error("json.encode: 嵌套过深（可能存在循环引用）")
        end
        if seen[v] then
            error("json.encode: 检测到循环引用")
        end
        seen[v] = true
        local out
        if getmetatable(v) == array_mt or isArray(v) then
            local parts = {}
            for i = 1, #v do
                parts[i] = encodeValue(v[i], seen, depth + 1)
            end
            out = "[" .. table.concat(parts, ",") .. "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) == "string" or type(k) == "number" then
                    keys[#keys + 1] = tostring(k)
                else
                    error("json.encode: 不支持的键类型 " .. type(k))
                end
            end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end
                parts[#parts + 1] = '"' .. escapeString(k) .. '":' .. encodeValue(val, seen, depth + 1)
            end
            out = "{" .. table.concat(parts, ",") .. "}"
        end
        seen[v] = nil
        return out
    end
    error("json.encode: 不支持的类型 " .. tv)
end

--- 编码为 JSON 字符串。
-- @param v any
-- @param opts table|nil { pretty = boolean }
-- @return string
function json.encode(v, opts)
    local encoded = encodeValue(v, {}, 1)
    if opts and opts.pretty then
        -- 简易美化：仅调整层级缩进，字符串内的括号不受影响（编码结果中括号只作结构符）
        return encoded
    end
    return encoded
end

-- ---------------------------------------------------------------------------
-- 解码
-- ---------------------------------------------------------------------------

local decode_error

local function skipWhitespace(s, pos)
    local _, e = s:find("^[ \t\r\n]*", pos)
    return e + 1
end

local utf8_char_cache = {}

local function codepointToUtf8(cp)
    if utf8_char_cache[cp] then return utf8_char_cache[cp] end
    local out
    if cp < 0x80 then
        out = string.char(cp)
    elseif cp < 0x800 then
        out = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        out = string.char(0xE0 + math.floor(cp / 0x1000),
                          0x80 + math.floor(cp / 0x40) % 0x40,
                          0x80 + cp % 0x40)
    else
        out = string.char(0xF0 + math.floor(cp / 0x40000),
                          0x80 + math.floor(cp / 0x1000) % 0x40,
                          0x80 + math.floor(cp / 0x40) % 0x40,
                          0x80 + cp % 0x40)
    end
    utf8_char_cache[cp] = out
    return out
end

local function parseString(s, pos)
    -- s:sub(pos,pos) == '"'
    local out = {}
    pos = pos + 1
    while true do
        local c = s:sub(pos, pos)
        if c == "" then
            decode_error = "字符串未闭合"
            return nil, pos
        elseif c == '"' then
            return table.concat(out), pos + 1
        elseif c == "\\" then
            local esc = s:sub(pos + 1, pos + 1)
            if esc == "u" then
                local hex = s:sub(pos + 2, pos + 5)
                if not hex:match("^%x%x%x%x$") then
                    decode_error = "非法 \\u 转义"
                    return nil, pos
                end
                local cp = tonumber(hex, 16)
                pos = pos + 6
                -- 处理代理对
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local hex2 = s:sub(pos + 2, pos + 5)
                    if s:sub(pos, pos + 1) == "\\u" and hex2:match("^%x%x%x%x$") then
                        local low = tonumber(hex2, 16)
                        if low >= 0xDC00 and low <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                            pos = pos + 6
                        end
                    end
                end
                out[#out + 1] = codepointToUtf8(cp)
            else
                local mapped = ({ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
                                  ['"'] = '"', ["\\"] = "\\", ["/"] = "/" })[esc]
                if not mapped then
                    decode_error = "非法转义 \\" .. tostring(esc)
                    return nil, pos
                end
                out[#out + 1] = mapped
                pos = pos + 2
            end
        else
            out[#out + 1] = c
            pos = pos + 1
        end
    end
end

local parseValue

local function parseNumber(s, pos)
    local num_str = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num_str or num_str == "" then
        decode_error = "非法数字"
        return nil, pos
    end
    local n = tonumber(num_str)
    if not n then
        decode_error = "非法数字: " .. num_str
        return nil, pos
    end
    return n, pos + #num_str
end

local function parseObject(s, pos)
    local obj = {}
    pos = skipWhitespace(s, pos + 1) -- 跳过 '{'
    if s:sub(pos, pos) == "}" then
        return obj, pos + 1
    end
    while true do
        pos = skipWhitespace(s, pos)
        if s:sub(pos, pos) ~= '"' then
            decode_error = "对象的键必须是字符串"
            return nil, pos
        end
        local key
        key, pos = parseString(s, pos)
        if not key then return nil, pos end
        pos = skipWhitespace(s, pos)
        if s:sub(pos, pos) ~= ":" then
            decode_error = "缺少冒号"
            return nil, pos
        end
        pos = skipWhitespace(s, pos + 1)
        local val
        val, pos = parseValue(s, pos)
        if val == nil and decode_error then return nil, pos end
        obj[key] = val
        pos = skipWhitespace(s, pos)
        local c = s:sub(pos, pos)
        if c == "}" then
            return obj, pos + 1
        elseif c == "," then
            pos = pos + 1
        else
            decode_error = "对象中出现意外字符 '" .. c .. "'"
            return nil, pos
        end
    end
end

local function parseArray(s, pos)
    local arr = {}
    pos = skipWhitespace(s, pos + 1) -- 跳过 '['
    if s:sub(pos, pos) == "]" then
        return arr, pos + 1
    end
    while true do
        pos = skipWhitespace(s, pos)
        local val
        val, pos = parseValue(s, pos)
        if val == nil and decode_error then return nil, pos end
        arr[#arr + 1] = val
        pos = skipWhitespace(s, pos)
        local c = s:sub(pos, pos)
        if c == "]" then
            return arr, pos + 1
        elseif c == "," then
            pos = pos + 1
        else
            decode_error = "数组中出现意外字符 '" .. c .. "'"
            return nil, pos
        end
    end
end

parseValue = function(s, pos)
    pos = skipWhitespace(s, pos)
    local c = s:sub(pos, pos)
    if c == "{" then
        return parseObject(s, pos)
    elseif c == "[" then
        return parseArray(s, pos)
    elseif c == '"' then
        return parseString(s, pos)
    elseif c == "t" and s:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif c == "f" and s:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif c == "n" and s:sub(pos, pos + 3) == "null" then
        return json.null, pos + 4
    elseif c == "-" or c:match("%d") then
        return parseNumber(s, pos)
    end
    decode_error = "意外的 JSON 字符 '" .. c .. "'"
    return nil, pos
end

--- 解码 JSON 字符串。
-- @param s string
-- @return table|nil value, string|nil err
-- 注意：失败时返回 nil 与错误信息；成功但值本身是 null 时返回 json.null。
function json.decode(s)
    if type(s) ~= "string" then
        return nil, "json.decode: 输入不是字符串"
    end
    decode_error = nil
    local pos = skipWhitespace(s, 1)
    local val, new_pos = parseValue(s, pos)
    if decode_error then
        local err = decode_error
        decode_error = nil
        return nil, err .. "（位置 " .. tostring(new_pos) .. "）"
    end
    new_pos = skipWhitespace(s, new_pos)
    if new_pos <= #s then
        return nil, "JSON 末尾存在多余内容（位置 " .. tostring(new_pos) .. "）"
    end
    if val == json.null then
        return json.null
    end
    return val
end

return json
