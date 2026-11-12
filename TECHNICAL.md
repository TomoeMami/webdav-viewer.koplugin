# 技术说明（TECHNICAL）

本文档面向修改/调试插件的人。安装与使用见 [README.md](README.md)、[USAGE.md](USAGE.md)，模块接口契约见 [INTERFACE.md](INTERFACE.md)。

## 兼容性

### 版本要求

| KOReader 版本 | 结果 |
|---|---|
| nightly / master（`BookList.getCollateSortFunc` 已合入，2026-09 之后） | 正常工作 |
| 正式版 v2026.07.1 及更早 | 点击「浏览远程文件」立即崩溃 |

判定依据：

- `wdr/browser.lua` 第 25 行 `local BookList = require("ui/widget/booklist")`：`ui/widget/booklist.lua` 在 v2025.04 之后才进入正式版，v2023.10、v2024.11 都没有。
- 第 68/72 行 `BookList.getCollateSortFunc()`：该函数 **只存在于 master**，2026-09-17 的提交 *"Use BookList sort_func (#16069)"* 才引入；正式版 v2026.07.1 已确认没有。

所以在正式版上，`require("wdr.browser")` 一执行就会抛 `attempt to call field 'getCollateSortFunc' (a nil value)`，菜单回调未做保护，表现为 KOReader 直接崩溃（设备上不会生成 `koreader/crash.log`，因为是 Lua 层异常退出）。

### 如何确认设备上的版本

- KOReader 主菜单 → 帮助 → 关于，nightly 版本号形如 `v2026.07.2-322-gc3e5f75`；
- 或看 `koreader/help/quickstart-*-v<版本>.html` 的文件名（升级后首次打开帮助才会生成新文件，可能与实际版本不符，仅作参考）。

### 兼容旧版的改造思路（未实现）

在 `browser.lua` 里对 `BookList.getCollateSortFunc` 做回退即可同时兼容正式版：

```lua
local function name_sort()
    if type(BookList.getCollateSortFunc) == "function" then
        return BookList.getCollateSortFunc()
    end
    return function(a, b) return ffiUtil.strcoll(a.text, b.text) end
end
```

`natural` 排序可用 `require("sort").natsort_cmp()` 自行构造。注意正式版 BookList 的 `Menu:switchItemTable` 第 5 个参数（subtitle）同样需要确认。

## 目录结构

```
.
├── README.md                    安装与须知
├── USAGE.md                     使用手册（功能、进度、缓存、FAQ）
├── TECHNICAL.md                 本文件
├── INTERFACE.md                 模块接口契约（改接口前先改它）
├── LICENSE                      GPL-3.0
├── webdavreader.koplugin/       插件本体（安装到 koreader/plugins/）
│   ├── _meta.lua                插件元信息（菜单显示名/描述）
│   ├── main.lua                 入口：菜单注册、事件钩子、配置/缓存/进度界面
│   └── wdr/
│       ├── browser.lua          远程浏览界面（Menu 子类，界面层）
│       ├── cache.lua            临时缓存：路径、新鲜度、LRU 淘汰
│       ├── config.lua           多服务器配置（LuaSettings 封装）
│       ├── json.lua             轻量 JSON 编解码（纯 Lua）
│       ├── manager.lua          远程文件管理（删除/移动/重命名/建目录）
│       ├── progress.lua         进度桥接（doc_settings <-> 插件 JSON）
│       ├── session.lua          FileManager 与 Reader 两个实例间的会话状态
│       ├── store.lua            进度键生成与存储底层（纯逻辑）
│       └── webdav.lua           WebDAV 协议客户端（纯网络层，无 UI）
├── tests/                       桌面 Lua 5.1 单元测试（不在设备上运行）
└── tools/                       测试用 Lua 5.1 与 luaossl/lfs 原生模块（Linux x86_64）
```

调用方向：

```
main.lua ──> browser.lua ──> manager.lua ──> webdav.lua
   │              │
   │              └──> progress.lua（读取展示）/ cache.lua
   └──> progress.lua（Reader 事件钩子）/ config.lua
```

## 依赖的 KOReader 模块

界面层：`ui/widget/menu`、`ui/widget/booklist`、`ui/widget/buttondialog`、`ui/widget/infomessage`、`ui/widget/inputdialog`、`ui/widget/multiinputdialog`、`ui/widget/confirmbox`、`ui/widget/notification`、`ui/widget/progressbardialog`、`ui/widget/pathchooser`、`ui/uimanager`、`ui/network/manager`、`dispatcher`、`gettext`。

数据/网络层：`datastorage`、`docsettings`、`document/documentregistry`、`ffi/util`、`ffi/sha2`、`libs/libkoreader-lfs`、`luasocket`（`socket.http` / `ssl.https` / `ltn12`）、`socketutil`、`apps/filemanager/filemanagerutil`。

插件不引入任何需要单独安装的第三方库；`tools/` 里的 `lua`、`luac`、`lfs.so`、`luasocket/*.so` 仅供桌面测试。

## 数据与键格式

| 数据 | 位置 | 说明 |
|---|---|---|
| 服务器配置 | `koreader/settings/webdavreader.lua` | `servers[]`、`default_server` |
| 插件状态 | `koreader/settings/webdavreader_state.lua` | 上次服务器、每个服务器的上次目录、本地缓存路径 → 远程路径映射 |
| 进度 | `koreader/settings/webdavreader_progress.json` | 键为 `<服务器ID>/<远程相对路径>` |
| 缓存 | `koreader/data/webdavreader_cache/` | 文件名 `<哈希>_<原文件名><扩展名>` 扁平结构 |

要点：

- **服务器 ID 由地址派生**，改服务器名不影响已有进度；
- 进度里除了 `xpointer` / `page` / `percent`，还保存 KOReader 的 `cre_dom_version`。缺了它，KOReader 会认为文档曾用旧版本打开过而强制使用最旧 DOM 版本，导致 xpointer 对不上（参见 `readerrolling.lua`）；
- 同一路径在插件 JSON 与 sidecar 都有进度时按「较新的那份胜出」合并（`main.lua:onDocSettingsLoad`）；
- 缓存文件名带哈希，不同目录的同名文件不会互相覆盖。

## 开发与测试

`tools/lua`、`tools/luac` 是为本项目编译的 Lua 5.1（与 KOReader 的 LuaJIT 语法基线一致），是 **Linux x86_64 二进制**，Windows 上无法直接运行，需要在 Linux/WSL 里跑：

```bash
cd <repo>

# 全部单元测试（当前 460 个断言）
./tools/lua tests/run_all.lua

# 单个套件
./tools/lua tests/run_all.lua progress
./tools/lua tests/run_all.lua json store

# 语法检查
./tools/luac -p webdavreader.koplugin/main.lua
for f in webdavreader.koplugin/wdr/*.lua; do ./tools/luac -p "$f" || echo "FAIL $f"; done
```

端到端测试需要一台真实 WebDAV 服务器（服务器不通时集成测试自动 SKIP，不算失败）：

```bash
pip install wsgidav cheroot
python3 /tmp/wdav_server.py        # 监听 127.0.0.1:18080，根目录 /tmp/wdav_root
./tools/lua tests/test_integration.lua
```

## 部署到设备

### adb 可用时

```bash
adb push webdavreader.koplugin /sdcard/koreader/plugins/
```

### 只有 MTP 时

设备只暴露 MTP（华为部分平板在未真正开启 USB 调试时就是这样）也能安装：

1. Windows 资源管理器 → 设备「内部存储/koreader/plugins」
2. 把 `webdavreader.koplugin` 文件夹拖进去（文件夹层级会被创建）
3. 校验：回读文件逐个比对大小 / SHA256，全部一致后再重启 KOReader

部署后确认：

- `内部存储/koreader/plugins/webdavreader.koplugin/` 下 11 个文件（`_meta.lua`、`main.lua`、`wdr/` 9 个）；
- 重启后 `koreader/settings/webdavreader.lua` 会被创建（说明插件已加载、配置入口可用）；
- 若点击菜单崩溃，先按[兼容性](#兼容性)确认 KOReader 版本。

## 已知问题与排障

| 现象 | 原因 / 处理 |
|---|---|
| 点击「浏览远程文件」KOReader 崩溃 | KOReader 正式版缺少 `BookList.getCollateSortFunc`，升级到 nightly 即可 |
| TXT 里换字体不生效 | KOReader 对 TXT 默认用等宽字体渲染，与插件无关；开启「设置 → 样式 → 自动检测 TXT 文件排版」解决（上游 [koreader#13349](https://github.com/koreader/koreader/issues/13349)） |
| 移动文件报 `HTTP 502 Source and destination must have the same host name` | 某些严格实现（wsgidav）对 `Host` 头敏感；插件已显式发送带端口的 `Host`，若仍出现请核对地址中的端口 |
| 移动报「目标已存在」 | 有意设计：MOVE 带 `Overwrite: F`，不会静默覆盖 |
| 删除目录提示超过 8 层 / 2000 项 | 递归删除的安全阀，防止误删超大目录 |
| 从 KOReader 历史记录打开缓存文件，进度对应不上 | 需要 `webdavreader_state.lua` 里的本地路径映射；清过缓存后需重新从远程浏览界面打开 |
| 桌面测试全绿但设备上崩 | 桌面测试用的是 `tests/*_stubs.lua` 模拟 KOReader，覆盖不到真实 KOReader 的接口版本差异，务必以设备实测为准 |

## 设计取舍（为什么不用官方 cloudstorage）

官方 `cloudstorage` 插件也能连 WebDAV，但：

- 打开文件必须「先选下载目录 → 保存 → 再去文件管理器找」，不能直接打开；
- 进度依赖 KOReader sidecar，跟着本地路径走，清缓存即丢；
- 只能删除单文件，没有移动/重命名/建目录。

本插件的进度以远程路径为键，且缓存与进度解耦，所以清缓存、重装插件、换设备都不丢进度。

## 版本记录

| 版本 | 说明 |
|---|---|
| 未发版 | 首个公开版本：浏览/直接打开/进度/缓存/远程文件管理、多服务器 |
