-- SPDX-License-Identifier: GPL-3.0-or-later
--[[--
WebDAV 远程读取插件 —— 目录排序（纯数据层，不含 UI）

本模块只做两件事：
  * 描述「有哪些排序方式」（Sort.keys / Sort.resolve / Sort.getText）；
  * 对 browser.lua 构造好的菜单项数组做原地排序（Sort.sortItems）。

设计约束（见 INTERFACE.md）：
  * 不 require 任何 UI / KOReader 版本相关模块；gettext 与 ffi/util.strcoll 都用
    pcall 兜底，因此桌面 Lua 5.1 单测里可以直接 require；
  * 比较函数一律接收「item 表」，字段约定见下方各 compare* 的注释；
  * 所有比较函数都 nil 安全：字段缺失、参数为 nil、甚至传入非表值都不抛错；
  * Lua 5.1 语法（无 goto、无位运算），禁止 os.execute / io.popen。

item 字段约定（由 browser.lua 构造）：
    文件：{ text=, name=, is_folder=false, is_file=true, remote_path=,
            filesize=, modification=, created= }   -- 后三个可能为 nil
    目录：{ text=, name=, is_folder=true, is_file=false, remote_path= }

比较函数返回 true 表示「a 应排在 b 前面」；a、b 视为相等时返回 false。

@module koplugin.webdavreader.sort
--]]--

local Sort = {}

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
-- 字符串比较：KOReader 里用 ffiUtil.strcoll（C locale），桌面环境退化为字节比较
-- ---------------------------------------------------------------------------

local function resolveStrColl()
    local ok, ffiUtil = pcall(require, "ffi/util")
    if ok and type(ffiUtil) == "table" and type(ffiUtil.strcoll) == "function" then
        return function(a, b) return ffiUtil.strcoll(a, b) end
    end
    return function(a, b) return a < b end
end

local strcoll = resolveStrColl()

-- ---------------------------------------------------------------------------
-- 排序方式表
-- ---------------------------------------------------------------------------

Sort.DEFAULT_KEY = "name"

--- 可选排序方式（数组顺序即 UI 菜单顺序，固定为 6 项）。
-- 每项字段：
--   key        : 字符串 id，作为 sortItems opts.key 使用
--   text       : 面向用户的文案（已过 gettext）
--   descending : boolean，该键的「内建自然方向」；true 表示新→旧（降序）
--   date_based : boolean，true 表示列表右侧应显示日期而不是大小
Sort.keys = {
    { key = "name", text = _("名称"), descending = false, date_based = false },
    { key = "name_natural", text = _("名称（自然排序）"), descending = false, date_based = false },
    { key = "modified", text = _("修改时间"), descending = true, date_based = true },
    { key = "created", text = _("创建时间"), descending = true, date_based = true },
    { key = "size", text = _("大小"), descending = false, date_based = false },
    { key = "type", text = _("类型"), descending = false, date_based = false },
}

--- key -> 上面的元素（供 O(1) 查表，不要修改里面的字段）。
Sort.KEY_BY_ID = {}
for i = 1, #Sort.keys do
    local spec = Sort.keys[i]
    Sort.KEY_BY_ID[spec.key] = spec
end

--- 把任意输入解析成合法排序键；未知 / 非字符串一律回退 DEFAULT_KEY。
-- @param key string|nil
-- @return string 合法 key
function Sort.resolve(key)
    if type(key) == "string" and Sort.KEY_BY_ID[key] ~= nil then
        return key
    end
    return Sort.DEFAULT_KEY
end

--- 取排序键的显示文案；未知键回退 name 的文案。
-- @param key string|nil
-- @return string 面向用户的文案
function Sort.getText(key)
    local spec = Sort.KEY_BY_ID[Sort.resolve(key)]
    return spec.text
end

-- ---------------------------------------------------------------------------
-- item 字段访问（全部 nil 安全）
-- ---------------------------------------------------------------------------

local function isTable(v)
    return type(v) == "table"
end

--- 取用于排序的文件名：name 优先，缺省回退 text，两者都缺回退 ""。
local function itemName(item)
    if not isTable(item) then return "" end
    local name = item.name
    if name == nil then
        name = item.text
    end
    if name == nil then return "" end
    return tostring(name)
end

--- 取用于最终 tie-break 的显示文本。
local function itemText(item)
    if not isTable(item) then return "" end
    local text = item.text
    if text == nil then return "" end
    return tostring(text)
end

--- 取数字字段（容忍数字字符串）；（缺值 / 非数字）返回 nil。
local function numberField(item, field)
    if not isTable(item) then return nil end
    local v = item[field]
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) end
    return nil
end

--- 是否目录项。
local function isFolder(item)
    if not isTable(item) then return false end
    return item.is_folder and true or false
end

--- 是否是「返回上一级」这一行（KOReader 的 is_go_up 约定）。
-- 它是导航控件而非目录内容，排序时必须永远置顶。
local function isGoUp(item)
    if not isTable(item) then return false end
    return item.is_go_up and true or false
end

-- ---------------------------------------------------------------------------
-- 比较函数（公开，Lead / 测试可直接调用）
-- ---------------------------------------------------------------------------

--- 纯字符串比较：s1 < s2 时返回 true。nil 视为 ""。
-- @param s1 string|nil
-- @param s2 string|nil
-- @return boolean
function Sort.compareStrings(s1, s2)
    if s1 == nil then s1 = "" else s1 = tostring(s1) end
    if s2 == nil then s2 = "" else s2 = tostring(s2) end
    if s1 == s2 then return false end
    return strcoll(s1, s2)
end

--- 按名称比较：name 字典序（locale/字节序），缺 name 回退 text，两者都缺视为相等。
-- @param a table|nil item
-- @param b table|nil item
-- @return boolean a 在前时为 true
function Sort.compareNames(a, b)
    return Sort.compareStrings(itemName(a), itemName(b))
end

-- 自然排序的键缓存：同一批文件名会被 table.sort 反复比较，转换一次即可。
-- 用一个简单的上限避免长时间运行后无限增长（超限直接清空重来）。
local NATSORT_CACHE_LIMIT = 4096
local natsort_cache = {}
local natsort_cache_count = 0

--- 把字符串转成「自然排序键」：数字段补零后按字符串比较（a2 < a10）。
-- 算法与 KOReader frontend/sort.lua 的 natsort_conv 一致（自包含实现，不依赖它）。
local function natsortConv(s)
    local res, dot = "", ""
    for n, m, c in s:gmatch("(0*(%d*))(.-)") do
        if n == "" then
            dot, c = "", dot .. c
        else
            res = res .. (dot == "" and string.format("%03d%s", #m, m) or "." .. n)
            dot, c = c:match("(%.?)(.*)")
        end
        res = res .. c:gsub("[%z\1-\127\192-\255]", "\0%0")
    end
    return res
end

local function natsortKey(s)
    local key = natsort_cache[s]
    if key == nil then
        key = natsortConv(s)
        if natsort_cache_count >= NATSORT_CACHE_LIMIT then
            natsort_cache = {}
            natsort_cache_count = 0
        end
        natsort_cache[s] = key
        natsort_cache_count = natsort_cache_count + 1
    end
    return key
end

--- 自然排序：数字段按数值比较（"a2" < "a10"），非数字段按 locale 比较。
-- 自然键完全相同（例如 "a2" 与 "a02"）时再退回原始字符串比较，保证结果确定。
-- @param a table|nil item
-- @param b table|nil item
-- @return boolean
function Sort.compareNamesNatural(a, b)
    local sa, sb = itemName(a), itemName(b)
    if sa == sb then return false end
    local ka, kb = natsortKey(sa), natsortKey(sb)
    if ka ~= kb then return ka < kb end
    return strcoll(sa, sb)
end

--- 修改时间比较：**新的在前**（a.modification > b.modification 时为 true）。
-- 一方缺值（nil / 非数字）时，缺值的那方返回 false —— 即永远排在后面；
-- 双方都缺值返回 false（视为相等，交给调用方按名称 tie-break）。
-- @param a table|nil item
-- @param b table|nil item
-- @return boolean
function Sort.compareModified(a, b)
    local va = numberField(a, "modification")
    local vb = numberField(b, "modification")
    if va == nil then return false end
    if vb == nil then return true end
    return va > vb
end

--- 创建时间比较：语义与 compareModified 完全相同，但只看 created 字段。
-- @param a table|nil item
-- @param b table|nil item
-- @return boolean
function Sort.compareCreated(a, b)
    local va = numberField(a, "created")
    local vb = numberField(b, "created")
    if va == nil then return false end
    if vb == nil then return true end
    return va > vb
end

--- 大小比较：a.filesize < b.filesize 时为 true；nil 视为 0。
-- @param a table|nil item
-- @param b table|nil item
-- @return boolean
function Sort.compareSize(a, b)
    local va = numberField(a, "filesize") or 0
    local vb = numberField(b, "filesize") or 0
    return va < vb
end

--- 取扩展名（小写、不含点）；没有扩展名返回 ""。
local function extensionOf(name)
    local ext = name:match("%.([^./\\]+)$")
    if not ext then return "" end
    return ext:lower()
end

--- 类型比较：先比扩展名（小写），扩展名相同再比名称。
-- @param a table|nil item
-- @param b table|nil item
-- @return boolean
function Sort.compareTypes(a, b)
    local na, nb = itemName(a), itemName(b)
    local ea, eb = extensionOf(na), extensionOf(nb)
    if ea ~= eb then
        return ea < eb
    end
    return Sort.compareStrings(na, nb)
end

-- ---------------------------------------------------------------------------
-- 方向与分组工具
-- ---------------------------------------------------------------------------

--- 把「a<b 为真」的 cmp 套上方向取反。
-- 相等情形（两个方向都不为 true）返回 nil，交给调用方做 tie-break，
-- 这样相等元素不会在 table.sort 里抖动。
-- @return boolean|nil
local function ordered(cmp, a, b, reverse)
    if cmp(a, b) then
        return not reverse
    end
    if cmp(b, a) then
        return reverse
    end
    return nil
end

--- 名称比较 + 方向取反（目录之间、以及所有 tie-break 都用它）。
local function orderedNames(a, b, reverse)
    return ordered(Sort.compareNames, a, b, reverse)
end

--- 日期键比较：先按「有没有值」分组 —— 有值的排前面、缺值的排后面，
-- 且这个分组与方向无关（所以 reverse 时缺值项仍然在最后）；
-- 只在两侧都有值时应用内建方向（新→旧）与 reverse。
-- 两侧都缺值返回 nil，让调用方按名称 tie-break。
-- @return boolean|nil
local function orderedByDate(cmp, field, a, b, reverse)
    local va = numberField(a, field)
    local vb = numberField(b, field)
    if va == nil and vb == nil then return nil end
    if va == nil then return false end
    if vb == nil then return true end
    return ordered(cmp, a, b, reverse)
end

--- 计算「是否需要取反」：opts.descending 是用户视角的真实方向（false=升序、
--- true=降序），每个键另有内建自然方向 spec.descending，两者不同就取反。
local function wantsReverse(opts, spec)
    local descending = opts.descending
    if descending == nil then
        descending = spec.descending
    else
        descending = descending and true or false
    end
    return (descending ~= spec.descending) and true or false
end

-- ---------------------------------------------------------------------------
-- sortItems
-- ---------------------------------------------------------------------------

--- 原地排序 item 数组并返回它。
--
-- @param items table|nil item 数组；nil / 非表值返回空表 {}，空表安全。
-- @param opts table|nil {
--     key         = 排序键（Sort.keys[].key 之一），未知值回退 DEFAULT_KEY；
--     descending  = boolean|nil 用户视角的真实方向，false=升序、true=降序；
--                   省略时使用该键的内建自然方向（modified/created 为新→旧）；
--     folders_first = boolean|nil 目录优先，默认 true；
--   }
-- @return table 传入的同一个 items（原地排序）；items 非法时返回新的空表
--
-- 排序规则（browser.lua 依赖这些语义）：
--   * folders_first=true（默认）：目录整块排在文件前面；
--   * 目录之间**永远按名称**（compareNames），方向跟随 descending —— 日期/大小键下
--     不会因为目录缺 modification/filesize 而被甩到文件后面；
--   * 文件按 key 比较；key 相等时依次按名称（compareNames）、再按 text 做 tie-break，
--     因此排序结果完全确定；
--   * 日期键下缺值（modification/created 为 nil）的文件排在最后，reverse 时也一样；
--   * folders_first=false：目录与文件混排，全部按 key 比较。日期键下目录没有日期，
--     因此归入「缺值组」排在最后 —— 这是为了避免「拿目录名和文件日期比较」这种
--     非传递的排序，保证比较器满足 table.sort 的严格弱序要求；
--   * size 键下 nil 大小按 0 处理（compareSize 语义），所以无大小的项（含
--     folders_first=false 时的目录）在升序里排最前、降序里排最后；
--   * type 键下按 compareTypes 处理：无扩展名的项扩展名视为 ""，排在带扩展名的前面，
--     同扩展名再按名称。
function Sort.sortItems(items, opts)
    if not isTable(items) then
        return {}
    end
    if opts == nil or not isTable(opts) then
        opts = {}
    end

    local key = Sort.resolve(opts.key)
    local spec = Sort.KEY_BY_ID[key]
    local reverse = wantsReverse(opts, spec)

    local folders_first = true
    if opts.folders_first ~= nil then
        folders_first = opts.folders_first and true or false
    end

    -- 主比较函数（只对「两个文件」或 folders_first=false 的任意两项生效）。
    local primary
    if key == "name" then
        primary = function(a, b) return ordered(Sort.compareNames, a, b, reverse) end
    elseif key == "name_natural" then
        primary = function(a, b) return ordered(Sort.compareNamesNatural, a, b, reverse) end
    elseif key == "modified" then
        primary = function(a, b)
            return orderedByDate(Sort.compareModified, "modification", a, b, reverse)
        end
    elseif key == "created" then
        primary = function(a, b)
            return orderedByDate(Sort.compareCreated, "created", a, b, reverse)
        end
    elseif key == "size" then
        primary = function(a, b) return ordered(Sort.compareSize, a, b, reverse) end
    else
        primary = function(a, b) return ordered(Sort.compareTypes, a, b, reverse) end
    end

    local function less(a, b)
        -- 「返回上一级」行（is_go_up）永远置顶，且不受排序键/方向影响。
        -- 它是导航控件而不是目录内容，跟着排序跑会让用户找不到回退入口。
        local ua, ub = isGoUp(a), isGoUp(b)
        if ua ~= ub then
            return ua
        end
        if ua and ub then
            return false
        end

        local fa, fb = isFolder(a), isFolder(b)
        if folders_first and fa ~= fb then
            return fa -- 目录优先
        end

        local result
        if fa and fb then
            -- 目录之间永远按名称（方向跟随 descending）
            result = orderedNames(a, b, reverse)
        else
            result = primary(a, b)
        end
        if result ~= nil then
            return result
        end

        -- tie-break 1：名称（**始终升序**，不跟随 descending —— 方向只属于主键，
        -- 让主键相等的项稳定地按 A→Z 排列，用户切换方向时组内顺序可预期）
        local by_name = orderedNames(a, b, false)
        if by_name ~= nil then
            return by_name
        end

        -- tie-break 2：显示文本（保证结果确定）
        local ta, tb = itemText(a), itemText(b)
        if ta ~= tb then
            return ta < tb
        end
        return false
    end

    table.sort(items, less)
    return items
end

return Sort
