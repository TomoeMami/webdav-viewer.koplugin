--[[--
wdr/json.lua 单元测试
--]]--

local M = {}

function M.run(T)
    local json = require("wdr.json")

    io.write("\n### json\n")

    T.test("编码基本类型", function()
        T.eq(json.encode(nil), "null")
        T.eq(json.encode(true), "true")
        T.eq(json.encode(false), "false")
        T.eq(json.encode(42), "42")
        T.eq(json.encode(-1), "-1")
        T.eq(json.encode(0), "0")
    end)

    T.test("编码字符串转义", function()
        T.eq(json.encode("abc"), '"abc"')
        T.eq(json.encode('a"b'), '"a\\"b"')
        T.eq(json.encode("a\\b"), '"a\\\\b"')
        T.eq(json.encode("a\nb"), '"a\\nb"')
        T.eq(json.encode("a\tb"), '"a\\tb"')
        T.eq(json.encode("a\rb"), '"a\\rb"')
        T.eq(json.encode("a\bb"), '"a\\bb"')
        T.eq(json.encode("a\fb"), '"a\\fb"')
    end)

    T.test("编码中文不转义", function()
        local out = json.encode("中文测试")
        T.eq(out, '"中文测试"')
        T.contains(out, "中文", "UTF-8 原样输出")
    end)

    T.test("编码控制字符转义为 \\u", function()
        local out = json.encode("a\1b")
        T.contains(out, "\\u0001", "控制字符应转成 \\u")
    end)

    T.test("编码数组", function()
        T.eq(json.encode({1, 2, 3}), "[1,2,3]")
        T.eq(json.encode({"a", "b"}), '["a","b"]')
    end)

    T.test("编码空表为对象", function()
        T.eq(json.encode({}), "{}")
    end)

    T.test("显式空数组", function()
        T.eq(json.encode(json.array({})), "[]")
        T.eq(json.encode(json.array({1})), "[1]")
    end)

    T.test("编码嵌套对象", function()
        local out = json.encode({ a = { b = { c = true } } })
        T.eq(out, '{"a":{"b":{"c":true}}}')
    end)

    T.test("编码键排序稳定", function()
        local out = json.encode({ z = 1, a = 2, m = 3 })
        T.eq(out, '{"a":2,"m":3,"z":1}')
    end)

    T.test("编码 null 哨兵", function()
        T.eq(json.encode(json.null), "null")
        T.eq(json.encode({ a = json.null }), '{"a":null}')
    end)

    T.test("编码 NaN/Inf 为 null", function()
        T.eq(json.encode(0/0), "null")
        T.eq(json.encode(1/0), "null")
        T.eq(json.encode(-1/0), "null")
    end)

    T.test("编码检测循环引用", function()
        local t = {}
        t.self = t
        T.raises(function() json.encode(t) end, "循环引用应报错")
    end)

    T.test("编码浮点数", function()
        T.eq(json.encode(0.5), "0.5")
        T.eq(json.encode(-0.25), "-0.25")
        -- 1/3 精度截断但可回读
        local back = json.decode(json.encode(1/3))
        T.near(back, 1/3, 1e-10, "浮点往返")
    end)

    T.test("解码基本类型", function()
        T.eq(json.decode("true"), true)
        T.eq(json.decode("false"), false)
        T.eq(json.decode("null"), json.null)
        T.eq(json.decode("42"), 42)
        T.eq(json.decode("-3.5"), -3.5)
        T.eq(json.decode("1e3"), 1000)
        T.eq(json.decode("1.5e-2"), 0.015)
    end)

    T.test("解码字符串", function()
        T.eq(json.decode('"abc"'), "abc")
        T.eq(json.decode('"a\\"b"'), 'a"b')
        T.eq(json.decode('"a\\nb"'), "a\nb")
        T.eq(json.decode('"a\\u4e2d"'), "a中")
        T.eq(json.decode('"\\ud83d\\ude00"'), "😀")
    end)

    T.test("解码数组与对象", function()
        local arr = json.decode("[1,2,3]")
        T.eq(#arr, 3)
        T.eq(arr[2], 2)

        local obj = json.decode('{"a":1,"b":[true,null]}')
        T.eq(obj.a, 1)
        T.eq(obj.b[1], true)
        T.eq(obj.b[2], json.null)
    end)

    T.test("解码忽略空白", function()
        local obj = json.decode('  {\n  "a" : 1 ,\n "b" : 2\n }  ')
        T.eq(obj.a, 1)
        T.eq(obj.b, 2)
    end)

    T.test("解码空结构", function()
        T.eq(#json.decode("[]"), 0)
        local o = json.decode("{}")
        T.is_table(o, "空对象")
        T.eq(next(o), nil)
    end)

    T.test("解码错误输入返回 nil+err", function()
        local v, err = json.decode("{bad")
        T.eq(v, nil)
        T.ok(err, "应有错误信息")

        v, err = json.decode("")
        T.eq(v, nil)

        v, err = json.decode('{"a":}')
        T.eq(v, nil)

        v, err = json.decode("[1,2")
        T.eq(v, nil)

        v, err = json.decode('"unterminated')
        T.eq(v, nil)
    end)

    T.test("解码非字符串输入", function()
        local v, err = json.decode(nil)
        T.eq(v, nil)
        T.contains(err, "不是字符串")
    end)

    T.test("解码尾部多余内容报错", function()
        local v, err = json.decode("{} extra")
        T.eq(v, nil)
        T.contains(err, "多余内容")
    end)

    T.test("往返一致性", function()
        local original = {
            version = 1,
            files = {
                ["abc123/books/三体.txt"] = {
                    percent = 0.4237,
                    page = 12,
                    total_pages = 300,
                    title = "三体.txt",
                    xpointer = "/body/DocFragment[3]/body/div/p[12]/text().0",
                    updated = 1700000000,
                },
                ["def456/notes/readme.md"] = {
                    percent = 1,
                    updated = 1700000001,
                },
            },
        }
        local encoded = json.encode(original)
        local decoded, err = json.decode(encoded)
        T.eq(err, nil)
        T.is_table(decoded, "解码结果")
        T.eq(decoded.version, 1)
        T.near(decoded.files["abc123/books/三体.txt"].percent, 0.4237, 1e-9)
        T.eq(decoded.files["abc123/books/三体.txt"].page, 12)
        T.eq(decoded.files["abc123/books/三体.txt"].title, "三体.txt")
        T.eq(decoded.files["def456/notes/readme.md"].percent, 1)
    end)

    T.test("往返保持空对象与空数组的区别", function()
        local original = { obj = {}, arr = json.array({}) }
        local encoded = json.encode(original)
        T.contains(encoded, '"obj":{}')
        T.contains(encoded, '"arr":[]')
    end)

    T.test("解码嵌套深度", function()
        local deep = string.rep("[", 20) .. "1" .. string.rep("]", 20)
        local v = json.decode(deep)
        T.is_table(v, "深层数组")
    end)

    return M
end

return M
