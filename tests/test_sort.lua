--[[--
wdr/sort.lua 单元测试（排序数据层）

覆盖：
  1. Sort.keys / KEY_BY_ID / resolve / getText 的契约（顺序、字段、未知键回退）
  2. 各比较函数的语义（item 版 + compareStrings），尤其是 nil / 缺值 / 相等
  3. sortItems：目录优先、目录永远按名、方向（descending）、tie-break、缺值排最后
  4. 未知键 / nil opts / nil items / 空字段的健壮性

排序方向约定（与 wdr/sort.lua 的文档一致）：
  * opts.descending 是「用户视角的真实方向」：false=升序、true=降序；
  * 省略时用该键的内建自然方向（modified/created 为新→旧，其余为升序）；
  * 内部取反标志 = (opts.descending ~= 键的内建 descending)。

@module tests.test_sort
--]]--

local M = {}

function M.run(T)
    local Sort = require("wdr.sort")

    io.write("\n### sort\n")

    -- -----------------------------------------------------------------------
    -- 一、排序方式表
    -- -----------------------------------------------------------------------

    T.test("keys：6 种排序方式且顺序固定", function()
        T.eq(#Sort.keys, 6, "排序方式数量")
        local expected = { "name", "name_natural", "modified", "created", "size", "type" }
        for i = 1, #expected do
            T.eq(Sort.keys[i].key, expected[i], "第 " .. i .. " 个排序键")
        end
    end)

    T.test("keys：每项字段齐全且 descending 语义正确", function()
        for i = 1, #Sort.keys do
            local spec = Sort.keys[i]
            T.eq(type(spec.text), "string", spec.key .. " 应有文案")
            T.ok(spec.text ~= "", spec.key .. " 文案非空")
            T.eq(type(spec.descending), "boolean", spec.key .. " descending 应是 boolean")
            T.eq(type(spec.date_based), "boolean", spec.key .. " date_based 应是 boolean")
            -- 只有日期键的内建方向是降序（新→旧）
            local want_descending = (spec.key == "modified" or spec.key == "created")
            T.eq(spec.descending, want_descending, spec.key .. " 的内建方向")
            T.eq(spec.date_based, want_descending, spec.key .. " 的 date_based")
            -- KEY_BY_ID 与数组里的元素是同一个对象
            T.ok(Sort.KEY_BY_ID[spec.key] == spec, spec.key .. " 应能在 KEY_BY_ID 里找到同一对象")
        end
    end)

    T.test("resolve：合法键原样返回，未知/非法回退 DEFAULT_KEY", function()
        T.eq(Sort.DEFAULT_KEY, "name")
        for i = 1, #Sort.keys do
            local key = Sort.keys[i].key
            T.eq(Sort.resolve(key), key)
        end
        T.eq(Sort.resolve("nope"), "name", "未知字符串")
        T.eq(Sort.resolve(""), "name", "空字符串")
        T.eq(Sort.resolve(nil), "name", "nil")
        T.eq(Sort.resolve(123), "name", "非字符串")
        T.eq(Sort.resolve(true), "name", "boolean")
        T.eq(Sort.resolve({ "name" }), "name", "table")
    end)

    T.test("getText：合法键返回对应文案，未知键回退 name 的文案", function()
        for i = 1, #Sort.keys do
            local spec = Sort.keys[i]
            T.eq(Sort.getText(spec.key), spec.text)
        end
        local name_text = Sort.KEY_BY_ID.name.text
        T.eq(Sort.getText("unknown"), name_text)
        T.eq(Sort.getText(nil), name_text)
        T.ok(name_text ~= Sort.KEY_BY_ID.type.text, "不同键的文案应不同")
    end)

    -- -----------------------------------------------------------------------
    -- 二、比较函数
    -- -----------------------------------------------------------------------

    T.test("compareStrings：nil 安全、相等返回 false", function()
        T.ok(Sort.compareStrings("a", "b"), "a < b")
        T.falsy(Sort.compareStrings("b", "a"), "b 不 < a")
        T.falsy(Sort.compareStrings("a", "a"), "相等返回 false")
        T.falsy(Sort.compareStrings(nil, nil), "双方 nil 视为相等")
        T.ok(Sort.compareStrings(nil, "a") == false or Sort.compareStrings(nil, "a") == true,
            "nil 与字符串比较不应抛错")
        T.eq(Sort.compareStrings(nil, "a"), "" < "a", "nil 视为空串")
        T.eq(Sort.compareStrings("a", nil), "a" < "", "nil 视为空串（反向）")
    end)

    local function file(name, opts)
        opts = opts or {}
        return {
            text = (opts.text or ("▤ " .. name)),
            name = name,
            is_folder = false,
            is_file = true,
            remote_path = opts.path or ("books/" .. name),
            filesize = opts.size,
            modification = opts.mtime,
            created = opts.ctime,
        }
    end

    local function folder(name, opts)
        opts = opts or {}
        return {
            text = "▣ " .. name,
            name = name,
            is_folder = true,
            is_file = false,
            remote_path = opts.path or ("books/" .. name),
        }
    end

    local function names(items)
        local out = {}
        for i = 1, #items do out[i] = items[i].name end
        return table.concat(out, ",")
    end

    T.test("compareNames：按 name 字典序，缺 name 回退 text", function()
        T.ok(Sort.compareNames(file("a.txt"), file("b.txt")))
        T.falsy(Sort.compareNames(file("b.txt"), file("a.txt")))
        T.falsy(Sort.compareNames(file("a.txt"), file("a.txt")), "同名相等")
        -- 缺 name 时用 text
        local no_name = { text = "aaa", is_file = true }
        local named = file("bbb.txt")
        T.ok(Sort.compareNames(no_name, named), "缺 name 应回退 text 比较")
        T.falsy(Sort.compareNames(nil, nil), "nil 项不应抛错")
        T.ok(Sort.compareNames(nil, file("a.txt")), "nil 视为空名，排在前面")
        T.falsy(Sort.compareNames(file("a.txt"), nil), "空名在后（反向）")
    end)

    T.test("compareNamesNatural：数字段按数值，a2 < a10", function()
        T.ok(Sort.compareNamesNatural(file("a2.txt"), file("a10.txt")), "a2 在 a10 前")
        T.falsy(Sort.compareNamesNatural(file("a10.txt"), file("a2.txt")))
        T.ok(Sort.compareNamesNatural(file("三体1.txt"), file("三体2.txt")))
        T.ok(Sort.compareNamesNatural(file("三体2.txt"), file("三体10.txt")), "2 < 10")
        T.falsy(Sort.compareNamesNatural(file("x1"), file("x1")), "完全相同返回 false")
        T.falsy(Sort.compareNamesNatural(nil, nil), "nil 安全")
        -- 自然排序与字典序在 "a10" 上的分歧（证明真的走了数值比较）
        T.ok(Sort.compareNames(file("a10.txt"), file("a2.txt")), "字典序下 a10 < a2")
        T.ok(Sort.compareNamesNatural(file("a2.txt"), file("a10.txt")), "自然序反之")
    end)

    T.test("compareModified：新的在前，缺值的一方永远返回 false", function()
        local older = file("a", { mtime = 100 })
        local newer = file("b", { mtime = 200 })
        T.ok(Sort.compareModified(newer, older), "新的在前")
        T.falsy(Sort.compareModified(older, newer), "旧的不在前")
        T.falsy(Sort.compareModified(older, older), "相等返回 false")
        -- 缺值
        local no_mtime = file("c")
        T.falsy(Sort.compareModified(no_mtime, older), "缺值的一方不在前")
        T.ok(Sort.compareModified(older, no_mtime), "有值的一方在前")
        T.falsy(Sort.compareModified(no_mtime, file("d")), "双方缺值视为相等")
        T.falsy(Sort.compareModified(nil, older), "nil 项不应抛错")
    end)

    T.test("compareCreated：只看 created，与 modification 互不影响", function()
        local a = file("a", { ctime = 100, mtime = 999 })
        local b = file("b", { ctime = 200, mtime = 1 })
        T.ok(Sort.compareCreated(b, a), "created 新者在前（即使 mtime 更旧）")
        T.ok(Sort.compareModified(a, b), "modified 新者在前（即使 ctime 更旧）")
        local no_ctime = file("c", { mtime = 500 })
        T.falsy(Sort.compareCreated(no_ctime, a), "缺 created 排后")
        T.ok(Sort.compareCreated(a, no_ctime), "有 created 排前")
        T.falsy(Sort.compareCreated(nil, nil), "nil 安全")
    end)

    T.test("compareSize：升序，nil 视为 0", function()
        T.ok(Sort.compareSize(file("a", { size = 1 }), file("b", { size = 2 })))
        T.falsy(Sort.compareSize(file("b", { size = 2 }), file("a", { size = 1 })))
        T.falsy(Sort.compareSize(file("a", { size = 5 }), file("b", { size = 5 })), "相等")
        T.falsy(Sort.compareSize(file("a"), file("b")), "双方 nil 视为 0-0 相等")
        T.ok(Sort.compareSize(file("a"), file("b", { size = 1 })), "nil 视为 0 → 排在前面")
        T.falsy(Sort.compareSize(file("a", { size = 1 }), file("b")), "有值的不小 0")
        T.falsy(Sort.compareSize(nil, nil), "nil 安全")
    end)

    T.test("compareTypes：先扩展名（小写）再名称", function()
        T.ok(Sort.compareTypes(file("a.epub"), file("b.pdf")), "epub < pdf")
        T.ok(Sort.compareTypes(file("b.EPUB"), file("a.pdf")), "扩展名比较不区分大小写")
        T.ok(Sort.compareTypes(file("a.epub"), file("b.epub")), "同扩展名再比名称")
        T.falsy(Sort.compareTypes(file("b.epub"), file("a.epub")))
        T.falsy(Sort.compareTypes(nil, nil), "nil 安全")
    end)

    -- -----------------------------------------------------------------------
    -- 三、sortItems
    -- -----------------------------------------------------------------------

    T.test("sortItems：默认 name 键升序 + 目录优先", function()
        local items = {
            file("b.txt"), folder("zdir"), file("a.txt"), folder("adir"),
        }
        local ret = Sort.sortItems(items)
        T.ok(ret == items, "应返回传入的同一个表（原地排序）")
        T.eq(names(items), "adir,zdir,a.txt,b.txt", "目录在前，各自按名升序")
    end)

    T.test("sortItems：folders_first=false 时混排", function()
        local items = { file("a.txt"), folder("b.dir"), file("c.txt") }
        Sort.sortItems(items, { key = "name", folders_first = false })
        T.eq(names(items), "a.txt,b.dir,c.txt", "全部按名称混排")
        T.eq(#items, 3, "元素不丢")
    end)

    T.test("sortItems：name 键 + descending=true 整体倒序（目录也倒序）", function()
        local items = { file("a.txt"), folder("adir"), file("c.txt"), folder("zdir") }
        Sort.sortItems(items, { key = "name", descending = true })
        T.eq(names(items), "zdir,adir,c.txt,a.txt", "目录仍在前，但目录内部与文件内部都倒序")
    end)

    T.test("sortItems：name_natural 数字段按数值排序", function()
        local items = { file("a10.txt"), file("a2.txt"), file("a1.txt") }
        Sort.sortItems(items, { key = "name_natural" })
        T.eq(names(items), "a1.txt,a2.txt,a10.txt")
        -- 对照：字典序下 a10 会在 a2 前面
        local plain = { file("a10.txt"), file("a2.txt") }
        Sort.sortItems(plain, { key = "name" })
        T.eq(names(plain), "a10.txt,a2.txt", "普通名称排序是字典序")
    end)

    T.test("sortItems：modified 默认新→旧，目录永远按名", function()
        local items = {
            file("old.txt", { mtime = 100 }),
            folder("zdir"),
            file("new.txt", { mtime = 300 }),
            folder("adir"),
            file("mid.txt", { mtime = 200 }),
        }
        Sort.sortItems(items, { key = "modified" })
        T.eq(names(items), "adir,zdir,new.txt,mid.txt,old.txt",
            "目录在前且按名升序（不受缺 modification 影响），文件新→旧")
    end)

    T.test("sortItems：modified + descending=false 变成旧→新", function()
        local items = {
            file("old.txt", { mtime = 100 }),
            file("new.txt", { mtime = 300 }),
            file("mid.txt", { mtime = 200 }),
        }
        Sort.sortItems(items, { key = "modified", descending = false })
        T.eq(names(items), "old.txt,mid.txt,new.txt", "用户要升序（旧→新）")
    end)

    T.test("sortItems：modified 缺值项排最后，descending=true 时仍排最后", function()
        local items = {
            file("none1.txt"),
            file("has.txt", { mtime = 50 }),
            file("none2.txt"),
            file("has2.txt", { mtime = 900 }),
        }
        Sort.sortItems(items, { key = "modified", descending = true })
        T.eq(items[1].name, "has2.txt", "有值且最新在前")
        T.eq(items[2].name, "has.txt", "有值次新")
        local tail = items[3].name .. "," .. items[4].name
        T.eq(tail, "none1.txt,none2.txt", "缺值项在最后，且按名称 tie-break")

        -- 反向再验一次：descending=false 时缺值项依旧在最后
        Sort.sortItems(items, { key = "modified", descending = false })
        T.eq(items[1].name, "has.txt", "升序时最早的在最前")
        T.eq(items[2].name, "has2.txt")
        T.eq(items[3].name, "none1.txt", "缺值项依然在最后")
    end)

    T.test("sortItems：created 键只看 created，不受 modification 影响", function()
        local items = {
            file("a.txt", { ctime = 300, mtime = 1 }),
            file("b.txt", { ctime = 100, mtime = 999 }),
            file("c.txt", { mtime = 500 }), -- 只有 modified，没有 created
        }
        Sort.sortItems(items, { key = "created" })
        T.eq(names(items), "a.txt,b.txt,c.txt",
            "created 新→旧，缺 created 的排最后（不拿 modified 冒充）")
        -- 同一批数据按 modified 排会是另一个顺序
        Sort.sortItems(items, { key = "modified" })
        T.eq(names(items), "b.txt,c.txt,a.txt", "modified 排序与 created 排序结果不同")
    end)

    T.test("sortItems：size 升序，nil 大小视为 0", function()
        local items = {
            file("big.txt", { size = 1000 }),
            folder("zdir"),
            file("nosize.txt"),
            folder("adir"),
            file("small.txt", { size = 10 }),
        }
        Sort.sortItems(items, { key = "size" })
        T.eq(names(items), "adir,zdir,nosize.txt,small.txt,big.txt",
            "目录按名在前；nil 大小按 0 排最前")
        Sort.sortItems(items, { key = "size", descending = true })
        T.eq(names(items), "zdir,adir,big.txt,small.txt,nosize.txt",
            "降序时目录也倒序，nil 视为 0 排最后")
    end)

    T.test("sortItems：type 键按扩展名分组", function()
        local items = {
            file("b.pdf"),
            file("c.epub"),
            folder("adir"),
            file("a.epub"),
            file("d.txt"),
        }
        Sort.sortItems(items, { key = "type" })
        T.eq(names(items), "adir,a.epub,c.epub,b.pdf,d.txt",
            "epub < pdf < txt，同扩展名按名称")
    end)

    T.test("sortItems：主键相等时按名称、再按 text 做确定的 tie-break", function()
        local items = {
            file("same.txt", { size = 5 }),
            file("aaa.txt", { size = 5 }),
        }
        Sort.sortItems(items, { key = "size" })
        T.eq(names(items), "aaa.txt,same.txt", "大小相同按名称")

        -- 名称也相同 → 用 text 兜底
        local a = file("dup.txt", { size = 5 })
        a.text = "▤ dup.txt (b)"
        local b = file("dup.txt", { size = 5 })
        b.text = "▤ dup.txt (a)"
        local dup = { a, b }
        Sort.sortItems(dup, { key = "size" })
        T.eq(dup[1].text, "▤ dup.txt (a)", "名称相同用 text 兜底")
        T.eq(dup[2].text, "▤ dup.txt (b)")
    end)

    T.test("sortItems：未知 key 回退 name，opts 为 nil / 非表不抛错", function()
        local items = { file("b.txt"), file("a.txt") }
        Sort.sortItems(items, { key = "no_such_key" })
        T.eq(names(items), "a.txt,b.txt", "未知 key 回退 name")

        local items2 = { file("d.txt"), file("c.txt") }
        Sort.sortItems(items2)
        T.eq(names(items2), "c.txt,d.txt", "opts 省略")

        local items3 = { file("f.txt"), file("e.txt") }
        Sort.sortItems(items3, "not a table")
        T.eq(names(items3), "e.txt,f.txt", "opts 非表")
    end)

    T.test("sortItems：nil / 空表安全", function()
        local empty = Sort.sortItems(nil)
        T.is_table(empty, "nil 应返回空表")
        T.eq(#empty, 0)
        local empty2 = Sort.sortItems({})
        T.eq(#empty2, 0, "空表安全")
        local empty3 = Sort.sortItems(nil, { key = "modified" })
        T.eq(#empty3, 0, "nil items + 有 opts")
    end)

    T.test("sortItems：字段缺失的 item 不抛错", function()
        local items = {
            { text = "只有 text 的文件", is_file = true },
            { name = "只有名字", is_file = true },
            file("normal.txt", { size = 3, mtime = 5, ctime = 6 }),
            { is_file = true },                      -- 什么都没有
            folder("dir"),
        }
        Sort.sortItems(items, { key = "modified" })
        T.eq(#items, 5, "元素数量不变")
        T.eq(items[1].name, "dir", "目录仍在最前")
        -- 剩下的文件里，有 modified 的排在缺值项之前
        T.eq(items[2].name, "normal.txt", "有修改时间的排在前")
        -- 三个缺值项按名称/文本升序（缺 name 回退 text，再缺视为 ""），固定为：
        --   ""（什么都没有） < "只有 text 的文件" < "只有名字"
        T.eq(items[3].name, nil, "缺一切字段的项视为空名，排在最前")
        T.eq(items[3].text, nil)
        T.eq(items[4].name, nil, "缺 name 的项回退 text 比较")
        T.eq(items[4].text, "只有 text 的文件")
        T.eq(items[5].name, "只有名字", "按名称排序")
    end)

    T.test("sortItems：大批量数据保持严格弱序（table.sort 不报错）", function()
        local items = {}
        for i = 1, 200 do
            if i % 7 == 0 then
                items[#items + 1] = folder("dir" .. i)
            else
                items[#items + 1] = file("f" .. (i % 37) .. ".txt", {
                    size = i % 5 == 0 and nil or i,
                    mtime = i % 11 == 0 and nil or i,
                })
            end
        end
        local keys = { "name", "name_natural", "modified", "created", "size", "type" }
        for _, key in ipairs(keys) do
            for _, descending in ipairs({ false, true }) do
                local copy = {}
                for i = 1, #items do copy[i] = items[i] end
                Sort.sortItems(copy, { key = key, descending = descending })
                T.eq(#copy, #items, key .. "/" .. tostring(descending) .. " 元素不丢")
                -- 目录仍在最前（folders_first 默认 true）
                local expect_folder = true
                for i = 1, #copy do
                    local is_dir = copy[i].is_folder and true or false
                    if is_dir then
                        T.ok(expect_folder, key .. "：" .. copy[i].name .. " 目录应在文件之前")
                    else
                        expect_folder = false
                    end
                end
            end
        end
    end)
end

return M
