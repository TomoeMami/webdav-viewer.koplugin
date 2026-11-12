-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
WebDAV 远程读取插件 —— 网络层（纯协议客户端，不含 UI）

设计要点：
  * 所有方法返回 (结果, err)。err 是可直接展示给用户的英文短句，本模块绝不抛异常、绝不弹窗。
  * 依赖延迟解析：socket.http / socketutil / util / ltn12 / gettext / logger 在每次调用时按
        package.loaded[name] -> pcall(require, name) -> 内置退化实现
    的顺序解析，因此：
        - 在 KOReader 里用真实实现；
        - 在桌面 Lua 5.1 单测里可以用 package.loaded["socket.http"] 注入假模块。
  * 超时：请求前 socketutil:set_timeout(block, total)，请求后必定 reset_timeout（全局规约 7）。
  * XML 解析不按「命名空间前缀」写死正则，而是先做一次轻量 XML 扫描建树，再按「本地名」
    （去掉前缀后的小写名）取元素，因此对 <d:> <D:> <lp1:> 无前缀、自闭合标签、属性顺序变化、
    元素顺序变化全都免疫。
  * 时间解析（HTTP-date / ISO8601）用纯算术换算成 UTC 秒，避免 os.time 受本地时区影响。

@module koplugin.webdavreader.webdav
--]]--

local M = {}

-- ---------------------------------------------------------------------------
-- 可翻译字符串（桌面环境下 gettext 不存在时退化为恒等函数）
-- ---------------------------------------------------------------------------

local _ = function(s) return s end
do
    local ok, gettext = pcall(require, "gettext")
    if ok and type(gettext) == "function" then
        _ = gettext
    end
end

-- ---------------------------------------------------------------------------
-- 依赖解析（延迟 + 可注入）
-- ---------------------------------------------------------------------------

-- 单测可直接注入：WebDAV.setDependencies{ http = ..., socketutil = ... }
-- 也可以按任务书的要求用 package.loaded["socket.http"] = fake 注入。
local injected_deps = nil

-- 模块名 -> 注入用的短键（"socket.http" 在注入表里写成 http，避免带点的键名）
local INJECT_KEYS = {
    ["socket.http"] = "http",
    ["ltn12"] = "ltn12",
    ["socketutil"] = "socketutil",
    ["util"] = "util",
    ["logger"] = "logger",
    ["gettext"] = "gettext",
}

--- 注入依赖（仅单测用；生产代码不要调用）。
-- @param deps table|nil { http=, ltn12=, socketutil=, util=, logger= }
function M.setDependencies(deps)
    injected_deps = deps
end

--- 解析依赖模块：注入表优先，其次 package.loaded，最后 require。
local function resolveModule(name)
    if injected_deps then
        local key = INJECT_KEYS[name]
        local injected = key and injected_deps[key]
        if injected then
            return injected
        end
    end
    local loaded = package.loaded[name]
    if loaded then
        return loaded
    end
    local ok, mod = pcall(require, name)
    if ok and mod then
        return mod
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 字符串工具（util 可用时优先用 KOReader 的实现，保证与设备行为一致）
-- ---------------------------------------------------------------------------

local function utf8Encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

--- 兜底：把 &amp; 与数字实体还原成 UTF-8（KOReader util.htmlEntitiesToUtf8 的等价实现）。
local function fallbackHtmlEntitiesToUtf8(text)
    if type(text) ~= "string" then return text end
    local t = text
    t = t:gsub("&#[xX](%x+);", function(h) return utf8Encode(tonumber(h, 16) or 63) end)
    t = t:gsub("&#(%d+);", function(d) return utf8Encode(tonumber(d) or 63) end)
    t = t:gsub("&lt;", "<")
    t = t:gsub("&gt;", ">")
    t = t:gsub("&quot;", '"')
    t = t:gsub("&apos;", "'")
    t = t:gsub("&nbsp;", " ")
    -- &amp; 必须最后处理，否则会把 &amp;lt; 拆成 &lt;
    t = t:gsub("&amp;", "&")
    return t
end

--- 兜底：RFC 3986 百分号编码（保留 unreserved 集合与 preserve_chars）。
local function fallbackUrlEncode(s, preserve_chars)
    if s == nil then return nil end
    s = tostring(s)
    local keep = {}
    local function addChar(c) keep[c] = true end
    local function addRange(a, b)
        for code = a:byte(), b:byte() do
            keep[string.char(code)] = true
        end
    end
    addRange("A", "Z")
    addRange("a", "z")
    addRange("0", "9")
    addChar("-"); addChar("."); addChar("_"); addChar("~")
    local preserve = preserve_chars or ""
    for i = 1, #preserve do
        addChar(preserve:sub(i, i))
    end
    return (s:gsub(".", function(c)
        if keep[c] then return c end
        return string.format("%%%02X", string.byte(c))
    end))
end

--- 兜底：百分号解码（不把 + 当成空格，WebDAV 的 href 不做 query 语义）。
local function fallbackUrlDecode(s)
    if s == nil then return nil end
    return (tostring(s):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function urlEncode(s, preserve_chars)
    local util = resolveModule("util")
    if util and type(util.urlEncode) == "function" then
        return util.urlEncode(s, preserve_chars)
    end
    return fallbackUrlEncode(s, preserve_chars)
end

local function urlDecode(s)
    local util = resolveModule("util")
    if util and type(util.urlDecode) == "function" then
        return util.urlDecode(s)
    end
    return fallbackUrlDecode(s)
end

local function htmlEntitiesToUtf8(s)
    local util = resolveModule("util")
    if util and type(util.htmlEntitiesToUtf8) == "function" then
        return util.htmlEntitiesToUtf8(s)
    end
    return fallbackHtmlEntitiesToUtf8(s)
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- href 解码：先还原 XML 实体，再做百分号解码（契约要求两者都做）。
local function decodeHref(href)
    if type(href) ~= "string" then return nil end
    return urlDecode(htmlEntitiesToUtf8(href))
end

-- ---------------------------------------------------------------------------
-- 路径工具
-- ---------------------------------------------------------------------------

--- 规范化「相对路径」：无前导斜杠、无尾斜杠、压缩重复斜杠。根目录返回 ""。
local function normalizeRel(path)
    if path == nil then return "" end
    return (tostring(path):gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/"))
end

--- 规范化「绝对路径」：保证有前导斜杠、去掉尾斜杠（根保留 "/"）。
local function normalizeAbs(path)
    local p = tostring(path or "")
    p = p:gsub("\\", "/"):gsub("/+", "/")
    if not p:match("^/") then p = "/" .. p end
    if #p > 1 then p = p:gsub("/+$", "") end
    if p == "" then p = "/" end
    return p
end

--- 取路径最后一段。
local function basename(path)
    local p = tostring(path or ""):gsub("/+$", "")
    return p:match("([^/]+)$") or ""
end

--- 拼接两个相对路径段。
local function joinRel(dir, name)
    local d = normalizeRel(dir)
    local n = normalizeRel(name)
    if d == "" then return n end
    if n == "" then return d end
    return d .. "/" .. n
end

--- 从完整 URL 或地址中取出「主机之后」的路径部分（不含 query/fragment）。
local function addressPath(address)
    local a = trim(tostring(address or ""))
    local p = a:match("^%a[%w%+%-%.]*://[^/]*(.*)$")
    if not p then
        p = a:match("^/") and a or ""
    end
    p = p:match("^[^?#]*") or ""
    return normalizeAbs(p)
end

--- href（已解码）→ 服务器上的绝对路径。域名部分丢弃。
local function hrefToPath(href)
    local p = tostring(href or "")
    local hostless = p:match("^%a[%w%+%-%.]*://[^/]*(.*)$")
    if hostless then
        p = hostless
    end
    p = p:match("^[^?#]*") or p
    if p == "" then return "/" end
    return p
end

--- 把绝对路径 p 中属于 base 的前缀剥掉；不属于 base 时返回 nil。
local function stripBasePath(p, base)
    if base == "" or base == "/" then return p end
    if p == base then return "/" end
    if p:sub(1, #base + 1) == base .. "/" then
        return p:sub(#base + 1)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- joinUrl：地址 + 相对路径 -> 请求 URL
-- ---------------------------------------------------------------------------

--- 从服务器地址推导 HTTP Host 头（含非默认端口）。
-- @param address string 形如 "https://nas.local:5006/dav"
-- @return string|nil 例如 "nas.local:5006"；无法解析时返回 nil
function M.getHostHeader(address)
    local addr = trim(tostring(address or ""))
    local scheme, hostport = addr:match("^([%a]+)://([^/]+)")
    if not hostport or hostport == "" then return nil end
    -- 去掉可能存在的 userinfo（http://user:pass@host:port）
    hostport = hostport:match("@(.+)$") or hostport
    if hostport == "" then return nil end

    local host, port = hostport:match("^(.-):(%d+)$")
    if host and port then
        local scheme_l = (scheme or ""):lower()
        local default_port = (scheme_l == "https" and "443") or (scheme_l == "http" and "80") or nil
        if default_port and port == default_port then
            -- 默认端口按 RFC 可以省略，这里也给出去掉端口的形态（兼容性最好）
            return host
        end
        return host .. ":" .. port
    end
    return hostport
end

--- 拼接服务器地址与相对路径。
-- @param address string 服务器地址，如 "https://host/dav"（末尾斜杠可有可无）
-- @param path string 相对路径（原始未编码的 UTF-8 文本；"/" 分隔符会被保留）
-- @param opts table|nil { trailing_slash = bool }
-- @return string
function M.joinUrl(address, path, opts)
    opts = opts or {}
    local base = trim(tostring(address or "")):gsub("/+$", "")
    local rel = normalizeRel(path)
    local encoded = urlEncode(rel, "/") or ""

    if encoded == "" then
        if opts.trailing_slash or base == "" then
            return (base ~= "" and (base .. "/") or "/")
        end
        return base
    end

    local out
    if base ~= "" then
        out = base .. "/" .. encoded
    else
        out = "/" .. encoded
    end
    if opts.trailing_slash then
        out = out .. "/"
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 轻量 XML 扫描器（够用即可：只需要元素树、元素文本、自闭合与任意前缀）
-- ---------------------------------------------------------------------------

--- 找到标签结束的 ">"，跳过属性值引号内的 ">"。
local function findTagEnd(xml, from)
    local i = from
    local quote = nil
    local n = #xml
    while i <= n do
        local c = xml:sub(i, i)
        if quote then
            if c == quote then quote = nil end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == ">" then
            return i
        end
        i = i + 1
    end
    return nil
end

--- 取标签的本地名（去前缀、小写）。
local function localName(name)
    local l = name:match("([^:]+)$") or name
    return l:lower()
end

--- 把 XML 文本扫描成元素树。容错：未闭合标签 / 截断文档不会报错，只是少几个节点。
-- @return table root { lname = "#root", children = {}, text = {} }
local function parseXmlTree(xml)
    local root = { lname = "#root", children = {}, text = {} }
    local stack = { root }
    local i = 1
    local n = #xml

    while i <= n do
        local s = xml:find("<", i, true)
        if not s then
            local top = stack[#stack]
            top.text[#top.text + 1] = xml:sub(i, n)
            break
        end
        if s > i then
            local top = stack[#stack]
            top.text[#top.text + 1] = xml:sub(i, s - 1)
        end

        if xml:sub(s, s + 3) == "<!--" then
            local e = xml:find("-->", s + 4, true)
            if not e then break end
            i = e + 3
        elseif xml:sub(s, s + 8) == "<![CDATA[" then
            local e = xml:find("]]>", s + 9, true)
            if not e then break end
            local top = stack[#stack]
            top.text[#top.text + 1] = xml:sub(s + 9, e - 1)
            i = e + 3
        else
            local e = findTagEnd(xml, s + 1)
            if not e then break end
            local raw = xml:sub(s + 1, e - 1)
            i = e + 1

            if raw:sub(1, 1) == "?" or raw:sub(1, 1) == "!" then
                -- XML 声明 / DOCTYPE，跳过
            elseif raw:sub(1, 1) == "/" then
                local name = raw:match("^/%s*([%w%-_%.:]+)")
                if name then
                    local want = localName(name)
                    for k = #stack, 2, -1 do
                        if stack[k].lname == want then
                            for j = #stack, k, -1 do stack[j] = nil end
                            break
                        end
                    end
                end
            else
                local name = raw:match("^%s*([%w%-_%.:]+)")
                if name then
                    local node = { lname = localName(name), name = name, children = {}, text = {} }
                    local top = stack[#stack]
                    top.children[#top.children + 1] = node
                    if not raw:match("/%s*$") then
                        stack[#stack + 1] = node
                    end
                end
            end
        end
    end
    return root
end

--- 深度优先取第一个指定本地名的后代元素。
local function firstDescendant(node, lname)
    if not node then return nil end
    for k = 1, #node.children do
        local child = node.children[k]
        if child.lname == lname then return child end
        local found = firstDescendant(child, lname)
        if found then return found end
    end
    return nil
end

--- 深度优先收集所有指定本地名的后代元素（保持文档顺序）。
local function collectDescendants(node, lname, out)
    out = out or {}
    for k = 1, #node.children do
        local child = node.children[k]
        if child.lname == lname then out[#out + 1] = child end
        collectDescendants(child, lname, out)
    end
    return out
end

--- 元素的直接文本（不含后代文本），已 trim。
local function nodeText(node)
    if not node then return nil end
    return trim(table.concat(node.text))
end

-- ---------------------------------------------------------------------------
-- 时间解析（纯算术，UTC，不依赖本地时区）
-- ---------------------------------------------------------------------------

local MONTHS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

--- Howard Hinnant 的 days_from_civil 算法：公历日期 -> 距 1970-01-01 的天数。
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function epochFrom(y, mo, d, h, mi, se, offset_seconds)
    y, mo, d, h, mi, se = tonumber(y), tonumber(mo), tonumber(d),
        tonumber(h), tonumber(mi), tonumber(se)
    if not (y and mo and d and h and mi and se) then return nil end
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or se > 60 then
        return nil
    end
    local t = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se
    if offset_seconds then
        t = t - offset_seconds
    end
    return t
end

--- 解析时区后缀：""/"Z"/"GMT"/"UTC" 视为 0，±HH:MM / ±HHMM 换算成秒。
-- 无法识别时返回 nil（调用方按 UTC 处理，绝不让本地时区影响结果）。
local function parseOffset(tail)
    if type(tail) ~= "string" then return nil end
    local t = trim(tail):gsub("^[%.%d]*", "")
    if t == "" then return 0 end
    if t:match("^[Zz]$") then return 0 end
    if t:upper() == "GMT" or t:upper() == "UTC" then return 0 end
    local sign, hh, mm = t:match("^([%+%-])(%d%d):?(%d%d)$")
    if sign then
        local off = tonumber(hh) * 3600 + tonumber(mm) * 60
        if sign == "-" then off = -off end
        return off
    end
    return nil
end

--- 解析 HTTP-date（RFC 1123 / RFC 850 / asctime）与 ISO 8601 时间。
-- @param s string
-- @return number|nil unix 秒（UTC）
function M.parseHttpDate(s)
    if type(s) ~= "string" then return nil end
    s = trim(s)
    if s == "" then return nil end

    -- ISO 8601 / RFC 3339：2024-11-12T09:30:15Z、2024-11-12T17:30:15+08:00、带小数秒
    do
        local y, mo, d, h, mi, se, tail = s:match(
            "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.-)$")
        if y then
            return epochFrom(y, mo, d, h, mi, se, parseOffset(tail))
        end
    end

    -- RFC 1123：Sun, 06 Nov 1994 08:49:37 GMT（也容忍 +0000 / +08:00 之类的数值时区）
    -- 不锚定开头，这样带不带星期几（"Sun, " / "Sunday, " / 完全不写）都能吃下。
    do
        local d, mo, y, h, mi, se, tail = s:match(
            "(%d%d?)%s+(%a%a%a+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s*(.-)%s*$")
        if d then
            local mon = MONTHS[mo:lower()]
            if not mon then return nil end
            return epochFrom(tonumber(y), mon, tonumber(d), tonumber(h),
                tonumber(mi), tonumber(se), parseOffset(tail))
        end
    end

    -- RFC 850：Sunday, 06-Nov-94 08:49:37 GMT
    do
        local d, mo, y, h, mi, se = s:match(
            "(%d%d?)%-(%a%a%a+)%-(%d%d%d?)%s+(%d%d):(%d%d):(%d%d)")
        if d then
            local mon = MONTHS[mo:lower()]
            if not mon then return nil end
            local year = tonumber(y)
            if year < 100 then
                year = year + (year < 70 and 2000 or 1900)
            end
            return epochFrom(year, mon, tonumber(d), tonumber(h),
                tonumber(mi), tonumber(se), parseOffset(s:match("([%+%-]%d%d%d%d)%s*$")))
        end
    end

    -- asctime：Sun Nov  6 08:49:37 1994
    do
        local mo, d, h, mi, se, y = s:match(
            "(%a%a%a+)%s+(%d%d?)%s+(%d%d):(%d%d):(%d%d)%s+(%d%d%d%d)")
        if mo then
            local mon = MONTHS[mo:lower()]
            if not mon then return nil end
            return epochFrom(tonumber(y), mon, tonumber(d), tonumber(h),
                tonumber(mi), tonumber(se), 0)
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- parseMultiStatus
-- ---------------------------------------------------------------------------

--- 判断一个 <response> 节点是否自带非 2xx 的状态（这类条目不可访问，直接丢弃）。
local function responseStatusNode(resp)
    for k = 1, #resp.children do
        if resp.children[k].lname == "status" then
            return resp.children[k]
        end
    end
    return nil
end

local function statusCodeOf(text)
    if type(text) ~= "string" then return nil end
    local code, tail = text:match("HTTP/[%d%.]+%s+(%d%d%d)%s*(.*)$")
    if not code then return nil end
    return tonumber(code), tail
end

--- 解析 PROPFIND 的 207 Multi-Status 响应体。
-- @param xml string 响应体
-- @param options table|nil {
--     self_href = "<完整 URL 或绝对路径>"  用于剔除「目录自身」条目
--     self_path = "<相对路径>"            同上，地址相对路径（优先级更高，更可靠）
--     address   = "<服务器地址>"          用于把 href 换算成「地址相对路径」
--     dir       = "<当前列出的相对目录>"  用于给不含 base 前缀的 href 兜底拼路径
--   }
-- @return table|nil items, string|nil err
--     items = { { name=, is_folder=, size=, modified=, href=, path= }, ... }
function M.parseMultiStatus(xml, options)
    options = options or {}

    if type(xml) ~= "string" then
        return nil, _("Empty response from server")
    end
    if xml:match("^%s*$") then
        return nil, _("Empty response from server")
    end
    if not xml:find("<", 1, true) then
        return nil, _("Response from server is not XML")
    end

    local root = parseXmlTree(xml)
    local multistatus = firstDescendant(root, "multistatus")
    if not multistatus then
        if xml:lower():find("<html", 1, true) then
            return nil, _("Server returned an HTML page instead of a WebDAV response")
        end
        return nil, _("Response is not a WebDAV Multi-Status document")
    end

    local base_path = ""
    if options.address and options.address ~= "" then
        base_path = addressPath(options.address)
    end
    local self_path
    if options.self_path ~= nil then
        self_path = normalizeRel(options.self_path)
    end
    local self_abs
    if type(options.self_href) == "string" and options.self_href ~= "" then
        self_abs = normalizeAbs(hrefToPath(decodeHref(options.self_href)))
    end
    local dir = normalizeRel(options.dir)

    local items = {}
    local responses = collectDescendants(multistatus, "response")

    for idx = 1, #responses do
        local resp = responses[idx]

        -- 1) 响应级状态过滤：403/404 之类的条目不是「当前目录的子项」
        local skip = false
        local status_node = responseStatusNode(resp)
        if status_node then
            local code = statusCodeOf(nodeText(status_node))
            if code and (code < 200 or code > 299) then
                skip = true
            end
        end

        -- 2) href
        local href_raw = nodeText(firstDescendant(resp, "href"))
        if not skip and href_raw and href_raw ~= "" then
            local href = decodeHref(href_raw)
            local abs_path = normalizeAbs(hrefToPath(href))
            local looks_relative = (not href:match("^/")) and (not href:match("^%a[%w%+%-%.]*://"))

            -- 3) 换算成「地址相对路径」
            local rel
            if looks_relative then
                rel = normalizeRel(hrefToPath(href))
            elseif base_path ~= "" then
                local stripped = stripBasePath(abs_path, base_path)
                if stripped then rel = normalizeRel(stripped) end
            else
                rel = normalizeRel(abs_path)
            end

            -- 4) 剔除目录自身条目
            local is_self = false
            if self_path ~= nil and rel ~= nil and rel == self_path then
                is_self = true
            end
            if not is_self and self_abs ~= nil and abs_path == self_abs then
                is_self = true
            end
            if not is_self then
                -- 5) 是否目录：resourcetype 里有 collection，或 href 以 "/" 结尾，
                --    或 IIS 风格的 iscollection 为真。
                local is_folder = false
                local rt = firstDescendant(resp, "resourcetype")
                if rt then
                    local collections = collectDescendants(rt, "collection")
                    if #collections > 0 then is_folder = true end
                end
                if not is_folder then
                    local iscollection = nodeText(firstDescendant(resp, "iscollection"))
                    if iscollection == "1" or iscollection == "true" then
                        is_folder = true
                    end
                end
                if not is_folder then
                    -- 只看 href 的路径部分是否以 / 结尾（query/fragment 先剥掉）
                    local raw_path = href:match("^[^?#]*") or href
                    if raw_path:sub(-1) == "/" then is_folder = true end
                end

                -- 6) 大小与修改时间
                local size = nil
                local size_text = nodeText(firstDescendant(resp, "getcontentlength"))
                if size_text and size_text ~= "" then
                    size = tonumber(size_text:match("^(%d+)"))
                end
                local modified = M.parseHttpDate(nodeText(firstDescendant(resp, "getlastmodified")))

                local name = basename(rel or abs_path or href)
                if name ~= "" and name ~= "." and name ~= ".." then
                    items[#items + 1] = {
                        name = name,
                        is_folder = is_folder,
                        size = size,
                        modified = modified,
                        href = href,
                        path = rel or joinRel(dir, name),
                    }
                end
            end
        end
    end

    return items, nil
end

-- ---------------------------------------------------------------------------
-- 错误文案
-- ---------------------------------------------------------------------------

local HTTP_REASONS = {
    [200] = "OK", [201] = "Created", [202] = "Accepted", [204] = "No Content",
    [207] = "Multi-Status", [301] = "Moved Permanently", [302] = "Found",
    [303] = "See Other", [304] = "Not Modified", [307] = "Temporary Redirect",
    [308] = "Permanent Redirect", [400] = "Bad Request", [401] = "Unauthorized",
    [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed",
    [408] = "Request Timeout", [409] = "Conflict", [412] = "Precondition Failed",
    [413] = "Payload Too Large", [415] = "Unsupported Media Type",
    [423] = "Locked", [424] = "Failed Dependency", [429] = "Too Many Requests",
    [500] = "Internal Server Error", [501] = "Not Implemented",
    [502] = "Bad Gateway", [503] = "Service Unavailable",
    [504] = "Gateway Timeout", [507] = "Insufficient Storage",
}

--- 由 HTTP 状态码生成人类可读的短句。
-- @param code number HTTP 状态码
-- @param status_line string|nil 服务器返回的状态行（用于补齐不认识的状态码）
-- @param hint string|nil 调用方给的上下文说明（如 "download failed"）
local function statusError(code, status_line, hint)
    local reason = HTTP_REASONS[code]
    if not reason and type(status_line) == "string" then
        reason = status_line:match("^HTTP/[%d%.]+%s+%d+%s+(.*)$")
    end
    local msg = string.format("HTTP %d %s", code, reason or "Error")

    -- 重定向优先解释：socket.http 不会替我们跟随 PROPFIND/MOVE 等非 GET 请求的 3xx，
    -- 若不解释清楚，用户只会看到一个莫名其妙的 301。
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        return msg .. " - the server redirected the request, please check the server address"
    end

    local default_hint
    if code == 401 then
        default_hint = "check the username and password"
    elseif code == 403 then
        default_hint = "access denied by the server"
    elseif code == 507 then
        default_hint = "not enough space on the server"
    end

    local final_hint = hint or default_hint
    if hint and default_hint and hint ~= default_hint then
        final_hint = default_hint .. " (" .. hint .. ")"
    end
    if final_hint then
        msg = msg .. " - " .. final_hint
    end
    return msg
end

-- ---------------------------------------------------------------------------
-- 内置 ltn12 兜底（桌面单测无 ltn12 时使用；语义与 ltn12 一致）
-- ---------------------------------------------------------------------------

local function makeStringSource(deps, body)
    local ltn12 = deps.ltn12
    if ltn12 and ltn12.source and ltn12.source.string then
        return ltn12.source.string(body)
    end
    local sent = false
    return function()
        if sent then return nil end
        sent = true
        return body
    end
end

local function makeTableSink(deps, chunks)
    local ltn12 = deps.ltn12
    if ltn12 and ltn12.sink and ltn12.sink.table then
        return (ltn12.sink.table(chunks))
    end
    return function(chunk)
        if chunk then chunks[#chunks + 1] = chunk end
        return 1
    end
end

--- 把本地文件读成 ltn12 风格的 source；返回 source 与 close 函数。
local function makeFileSource(handle)
    local closed = false
    local function close()
        if not closed then
            closed = true
            pcall(function() handle:close() end)
        end
    end
    local function source()
        local chunk = handle:read(8192)
        if chunk == nil or chunk == "" then
            return nil
        end
        return chunk
    end
    return source, close
end

-- ---------------------------------------------------------------------------
-- HTTP 结果归一化
-- ---------------------------------------------------------------------------

--- LuaSocket 的 http.request 有两种返回形态：
--    成功：(1, code, headers, status)
--    失败：(nil, err, headers, status)
-- 另外容忍被简化的假模块直接返回 (code, headers, status) 或 (ok, ...)。
-- @return code(number|nil), headers, status_line, transport_err(string|nil)
local function normalizeResult(a, b, c, d)
    if a == 1 then
        if type(b) == "number" then
            return b, c, d, nil
        end
        return nil, c, d, _("unexpected HTTP client response")
    elseif a == nil then
        -- 保留原始错误码（"timeout"/"closed" 等），由 _transportError 统一翻译
        return nil, c, d, tostring(b or "unknown network error")
    elseif type(a) == "number" then
        return a, b, c, nil
    elseif type(a) == "boolean" then
        if a then
            return tonumber(b) or 200, c, d, nil
        end
        return nil, c, d, tostring(b or "request failed")
    end
    return nil, nil, nil, _("unexpected HTTP client response")
end

--- 大小写不敏感地取响应头。
local function headerValue(headers, name)
    if type(headers) ~= "table" then return nil end
    local wanted = name:lower()
    for k, v in pairs(headers) do
        if type(k) == "string" and k:lower() == wanted then
            return v
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 依赖快照
-- ---------------------------------------------------------------------------

local FALLBACK_SOCKETUTIL = {
    FILE_BLOCK_TIMEOUT = 15,
    FILE_TOTAL_TIMEOUT = 60,
    set_timeout = function() end,
    reset_timeout = function() end,
}

local function getDeps()
    local deps = {}
    deps.http = resolveModule("socket.http")
    deps.ltn12 = resolveModule("ltn12")
    local socketutil = resolveModule("socketutil")
    deps.socketutil = socketutil or FALLBACK_SOCKETUTIL
    deps.logger = resolveModule("logger")
    deps.util = resolveModule("util")
    return deps
end

local PROPFIND_BODY = '<?xml version="1.0" encoding="utf-8"?>\n'
    .. '<d:propfind xmlns:d="DAV:"><d:prop>'
    .. '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
    .. '</d:prop></d:propfind>'

-- ---------------------------------------------------------------------------
-- 客户端对象
-- ---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

--- 绑定一个服务器配置，返回客户端对象（不修改传入的 table）。
-- @param server table { address=, username=, password=, start_dir= }
-- @param opts table|nil { timeout_block=, timeout_total= }
-- @return table client
function M.client(server, opts)
    server = server or {}
    opts = opts or {}
    local self = setmetatable({}, Client)

    self.address = trim(tostring(server.address or "")):gsub("/+$", "")
    self.username = server.username or ""
    self.password = server.password or ""
    self.start_dir = server.start_dir or "/"

    local socketutil = resolveModule("socketutil") or FALLBACK_SOCKETUTIL
    self.timeout_block = opts.timeout_block or socketutil.FILE_BLOCK_TIMEOUT or 15
    self.timeout_total = opts.timeout_total or socketutil.FILE_TOTAL_TIMEOUT or 60

    -- 预先算好 Host 头。
    -- 为什么必须自己算：luasocket 的 http 模块把默认头写成 ["host"] = reqt.host，
    -- 只取主机名、丢掉端口。对运行在非 80/443 端口的 WebDAV 服务器而言这是坏头：
    --   * RFC 7230 §5.4 要求 Host 必须包含非默认端口；
    --   * 严格实现（例如 wsgidav）会拿 Host 与 MOVE 的 Destination 比对，不一致就返回 502
    --     "Source and destination must have the same host name"。
    -- 这里显式给出带端口的 Host，交由 luasocket 的 "override with user headers" 逻辑覆盖默认值。
    self.host_header = M.getHostHeader(self.address)

    return self
end

function Client:_log(level, ...)
    local logger = resolveModule("logger")
    if logger and type(logger[level]) == "function" then
        pcall(logger[level], ...)
    end
end

--- 配置是否完整可用（地址为空或协议不对时返回英文错误）。
function Client:_configError()
    if self.address == "" then
        return _("Server address is not configured")
    end
    if not self.address:lower():match("^https?://") then
        return _("Invalid server address: it must start with http:// or https://")
    end
    return nil
end

function Client:_transportError(err)
    local msg = tostring(err or "unknown network error")
    if msg == "timeout" then
        -- socketutil 的超时错误码（KOReader 用 "timeout" 表示无响应）
        return _("Connection timed out, no response within ") .. tostring(self.timeout_block)
            .. _(" seconds")
    elseif msg == "wantread" or msg == "wantwrite" then
        return _("Secure connection timed out while establishing TLS")
    elseif msg == "closed" then
        return _("Connection closed by the server")
    end
    return _("Network error: ") .. msg
end

--- 执行一次原始 HTTP 请求。超时设置与复位都发生在这里，保证「请求后必 reset」。
-- @param args table { method=, url=, headers=, body=, source=, sink= }
-- @return code, headers, status_line, transport_err
function Client:_perform(args)
    local deps = getDeps()
    local http = deps.http
    if not http or type(http.request) ~= "function" then
        return nil, nil, nil, _("the HTTP client is not available")
    end

    local headers = {}
    for k, v in pairs(args.headers or {}) do
        headers[k] = v
    end
    -- luasocket 默认的 Host 头不含端口，这里显式覆盖（见 Client 构造处的说明）。
    if self.host_header and not headerValue(headers, "host") then
        headers["Host"] = self.host_header
    end

    local req = {
        url = args.url,
        method = args.method,
        headers = headers,
    }
    if self.username ~= "" then req.user = self.username end
    if self.password ~= "" then req.password = self.password end

    if args.source then
        req.source = args.source
    elseif args.body ~= nil and args.body ~= "" then
        req.source = makeStringSource(deps, args.body)
        if not headerValue(headers, "content-length") then
            headers["Content-Length"] = tostring(#args.body)
        end
    end
    if args.sink then
        req.sink = args.sink
    end

    self:_log("dbg", "WebDAV request:", args.method, args.url)

    local socketutil = deps.socketutil
    if socketutil and type(socketutil.set_timeout) == "function" then
        pcall(socketutil.set_timeout, socketutil, self.timeout_block, self.timeout_total)
    end

    local results = { pcall(http.request, req) }

    -- 契约要求：网络请求后必须 reset_timeout（无论成功失败）
    if socketutil and type(socketutil.reset_timeout) == "function" then
        pcall(socketutil.reset_timeout, socketutil)
    end

    if not results[1] then
        return nil, nil, nil, _("request error: ") .. tostring(results[2])
    end

    local code, resp_headers, status_line, transport_err =
        normalizeResult(results[2], results[3], results[4], results[5])

    if not code then
        self:_log("warn", "WebDAV transport failure:", transport_err)
    else
        self:_log("dbg", "WebDAV response:", code, status_line)
    end
    return code, resp_headers, status_line, transport_err
end

--- 发一次 PROPFIND。
-- @return code, headers, status_line, transport_err, body
function Client:_propfind(url, depth)
    local deps = getDeps()
    local chunks = {}
    local code, headers, status_line, transport_err = self:_perform({
        method = "PROPFIND",
        url = url,
        headers = {
            ["Content-Type"] = 'application/xml; charset="utf-8"',
            ["Depth"] = tostring(depth or "1"),
            ["Accept"] = "application/xml, text/xml, */*",
        },
        body = PROPFIND_BODY,
        sink = makeTableSink(deps, chunks),
    })
    return code, headers, status_line, transport_err, table.concat(chunks)
end

-- ---------------------------------------------------------------------------
-- list
-- ---------------------------------------------------------------------------

--- 列出目录的直接子项（不含目录自身）。
-- @param path string 相对路径，"" 表示根
-- @return table|nil items, string|nil err
function Client:list(path)
    local config_err = self:_configError()
    if config_err then return nil, config_err end

    local dir = normalizeRel(path)
    local url = M.joinUrl(self.address, dir, { trailing_slash = true })

    local code, discard_headers, status_line, transport_err, body = self:_propfind(url, "1")
    if not code then
        return nil, self:_transportError(transport_err)
    end
    if code ~= 207 then
        return nil, statusError(code, status_line, _("directory listing failed"))
    end

    local items, err = M.parseMultiStatus(body, {
        address = self.address,
        self_href = url,
        self_path = dir,
        dir = dir,
    })
    if not items then
        return nil, err
    end
    return items, nil
end

-- ---------------------------------------------------------------------------
-- download
-- ---------------------------------------------------------------------------

--- 下载远程文件到本地路径。
-- @param path string 远程相对路径
-- @param local_path string 本地绝对路径
-- @param opts table|nil { progress_cb = function(downloaded, total) }
-- @return boolean|nil ok, string|nil err
function Client:download(path, local_path, opts)
    opts = opts or {}
    local config_err = self:_configError()
    if config_err then return nil, config_err end
    if type(local_path) ~= "string" or local_path == "" then
        return nil, _("Local path is not specified")
    end

    local url = M.joinUrl(self.address, normalizeRel(path))
    local handle, open_err = io.open(local_path, "wb")
    if not handle then
        return nil, _("Cannot write to local file: ") .. tostring(open_err or local_path)
    end

    local deps = getDeps()
    local progress_cb = opts.progress_cb
    local downloaded = 0
    local write_failed = false

    local function sink(chunk)
        if not chunk then
            return 1
        end
        local ok, err = handle:write(chunk)
        if not ok then
            write_failed = true
            return nil, _("Cannot write to local file: ") .. tostring(err or local_path)
        end
        downloaded = downloaded + #chunk
        if progress_cb then
            -- 中途还不知道总大小（响应头要等请求返回才拿到），total 传 nil
            pcall(progress_cb, downloaded, nil)
        end
        return 1
    end

    local code, headers, status_line, transport_err = self:_perform({
        method = "GET",
        url = url,
        sink = sink,
    })

    pcall(function() handle:close() end)
    handle = nil

    if not code then
        pcall(os.remove, local_path)
        if write_failed then
            return nil, _("Cannot write to local file: ") .. local_path
        end
        return nil, self:_transportError(transport_err)
    end

    if code ~= 200 then
        pcall(os.remove, local_path)
        return nil, statusError(code, status_line, _("download failed"))
    end

    local expected = tonumber(headerValue(headers, "content-length"))
    if expected and downloaded < expected then
        pcall(os.remove, local_path)
        return nil, string.format(
            _("Download incomplete: received %d of %d bytes"), downloaded, expected)
    end

    if progress_cb then
        pcall(progress_cb, downloaded, expected or downloaded)
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- upload
-- ---------------------------------------------------------------------------

--- 上传本地文件到远程路径（PUT）。
-- @param local_path string 本地文件路径
-- @param remote_path string 远程相对路径
-- @return boolean|nil ok, string|nil err
function Client:upload(local_path, remote_path)
    local config_err = self:_configError()
    if config_err then return nil, config_err end

    local handle, open_err = io.open(local_path, "rb")
    if not handle then
        return nil, _("Cannot open local file: ") .. tostring(open_err or local_path)
    end

    local size = handle:seek("end")
    handle:seek("set", 0)

    local source, close = makeFileSource(handle)
    local url = M.joinUrl(self.address, normalizeRel(remote_path))

    local code, discard_headers, status_line, transport_err = self:_perform({
        method = "PUT",
        url = url,
        headers = {
            ["Content-Type"] = "application/octet-stream",
            ["Content-Length"] = tostring(size or 0),
        },
        source = source,
    })

    close()

    if not code then
        return nil, self:_transportError(transport_err)
    end
    if code < 200 or code > 299 then
        return nil, statusError(code, status_line, _("upload failed"))
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- delete / move / mkdir
-- ---------------------------------------------------------------------------

--- 删除文件或目录（DELETE，目录按 RFC 4918 递归删除）。
-- @param path string 远程相对路径
-- @return boolean|nil ok, string|nil err
function Client:delete(path)
    local config_err = self:_configError()
    if config_err then return nil, config_err end

    local deps = getDeps()
    local url = M.joinUrl(self.address, normalizeRel(path))
    local code, discard_headers, status_line, transport_err = self:_perform({
        method = "DELETE",
        url = url,
        sink = makeTableSink(deps, {}),
    })

    if not code then
        return nil, self:_transportError(transport_err)
    end
    if code < 200 or code > 299 then
        return nil, statusError(code, status_line, _("delete failed"))
    end
    return true, nil
end

--- 移动 / 重命名（MOVE）。
-- Destination 必须是绝对 URL；Overwrite 置为 "F"，目标已存在时要求服务器拒绝（412）。
-- @param from_path string 源相对路径
-- @param to_path string 目标相对路径
-- @return boolean|nil ok, string|nil err
function Client:move(from_path, to_path)
    local config_err = self:_configError()
    if config_err then return nil, config_err end

    local from_rel = normalizeRel(from_path)
    local to_rel = normalizeRel(to_path)
    if from_rel == "" or to_rel == "" then
        return nil, _("Source and destination must not be empty")
    end
    if from_rel == to_rel then
        return nil, _("Source and destination are the same")
    end

    local deps = getDeps()
    local destination = M.joinUrl(self.address, to_rel)
    local code, discard_headers, status_line, transport_err = self:_perform({
        method = "MOVE",
        url = M.joinUrl(self.address, from_rel),
        headers = {
            ["Destination"] = destination,
            ["Overwrite"] = "F",
        },
        sink = makeTableSink(deps, {}),
    })

    if not code then
        return nil, self:_transportError(transport_err)
    end
    if code < 200 or code > 299 then
        if code == 412 then
            return nil, statusError(code, status_line, _("the destination already exists"))
        end
        return nil, statusError(code, status_line, _("move failed"))
    end
    return true, nil
end

--- 新建目录（MKCOL）。
-- @param path string 远程相对路径
-- @return boolean|nil ok, string|nil err
function Client:mkdir(path)
    local config_err = self:_configError()
    if config_err then return nil, config_err end

    local rel = normalizeRel(path)
    if rel == "" then
        return nil, _("Directory name is not specified")
    end

    local deps = getDeps()
    local code, discard_headers, status_line, transport_err = self:_perform({
        method = "MKCOL",
        url = M.joinUrl(self.address, rel),
        sink = makeTableSink(deps, {}),
    })

    if not code then
        return nil, self:_transportError(transport_err)
    end
    if code < 200 or code > 299 then
        if code == 405 then
            return nil, statusError(code, status_line, _("the directory already exists"))
        end
        return nil, statusError(code, status_line, _("creating the directory failed"))
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- exists
-- ---------------------------------------------------------------------------

--- 探测路径是否存在。
-- @param path string 远程相对路径
-- @return boolean|nil exists, boolean|nil is_folder, string|nil err
function Client:exists(path)
    local config_err = self:_configError()
    if config_err then return nil, nil, config_err end

    local rel = normalizeRel(path)
    local url = M.joinUrl(self.address, rel)

    local code, discard_headers, status_line, transport_err, body = self:_propfind(url, "0")
    if not code then
        return nil, nil, self:_transportError(transport_err)
    end

    if code == 404 then
        return false, nil, nil
    end
    if code ~= 207 then
        return nil, nil, statusError(code, status_line, _("checking the path failed"))
    end

    -- Depth:0 时服务器必须返回该资源自身；不过滤 self 条目
    local items, err = M.parseMultiStatus(body, { address = self.address })
    if not items then
        return nil, nil, err
    end
    if #items == 0 then
        -- 207 但没有任何可解析条目：部分服务器用 response 级 404 表示不存在
        local failed = body:match("<[%w:%-_%.]*status[^>]*>%s*HTTP/[%d%.]+%s+(%d%d%d)")
        if tonumber(failed) == 404 then
            return false, nil, nil
        end
        return true, nil, nil
    end
    return true, items[1].is_folder and true or false, nil
end

-- ---------------------------------------------------------------------------
-- request（调试用原始请求）
-- ---------------------------------------------------------------------------

--- 原始请求。
-- @param method string HTTP 方法
-- @param path string 相对路径（或空，配合 opts.url 使用）
-- @param opts table|nil { headers=, body=, depth=, url=, trailing_slash= }
-- @return boolean ok, number|nil status_code, string body
function Client:request(method, path, opts)
    opts = opts or {}
    local config_err = self:_configError()
    if config_err then return false, nil, config_err end

    local url = opts.url or M.joinUrl(self.address, normalizeRel(path),
        { trailing_slash = opts.trailing_slash })

    local headers = {}
    for k, v in pairs(opts.headers or {}) do
        headers[k] = v
    end
    if opts.depth then
        headers["Depth"] = tostring(opts.depth)
    end

    local deps = getDeps()
    local chunks = {}
    local code, discard_headers, status_line, transport_err = self:_perform({
        method = method,
        url = url,
        headers = headers,
        body = opts.body,
        sink = makeTableSink(deps, chunks),
    })
    local body = table.concat(chunks)

    if not code then
        return false, nil, self:_transportError(transport_err)
    end
    return code >= 200 and code <= 299, code, body
end

return M
