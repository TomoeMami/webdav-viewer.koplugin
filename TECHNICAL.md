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
│       ├── history.lua          移动位置历史（每服务器 MRU 列表，纯逻辑）
│       ├── json.lua             轻量 JSON 编解码（纯 Lua）
│       ├── manager.lua          远程文件管理（删除/移动/重命名/建目录）
│       ├── progress.lua         进度桥接（doc_settings <-> 插件 JSON）
│       ├── session.lua          FileManager 与 Reader 两个实例间的会话状态
│       ├── sort.lua             目录排序（纯数据层：排序键、方向、目录优先）
│       ├── store.lua            进度键生成与存储底层（纯逻辑）
│       └── webdav.lua           WebDAV 协议客户端（纯网络层，无 UI）
├── tests/                       桌面 Lua 5.1 单元测试（不在设备上运行）
└── tools/                       测试用 Lua 5.1 与 luaossl/lfs 原生模块（Linux x86_64）
```

调用方向：

```
main.lua ──> browser.lua ──> manager.lua ──> webdav.lua
   │              │
   │              ├──> progress.lua（读取展示）/ cache.lua
   │              ├──> sort.lua（列表重排）/ history.lua（移动快捷位置）
   │              └──> config.lua（服务器与路径）
   └──> progress.lua（Reader 事件钩子）/ config.lua / history.lua（移动记录界面）
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
| 移动位置历史 | `koreader/settings/webdavreader_history.json` | 键为「服务器ID」→ 最近使用的目标目录数组（最多 20 条，MRU） |
| 缓存 | `koreader/data/webdavreader_cache/` | 文件名 `<哈希>_<原文件名><扩展名>` 扁平结构 |

要点：

- **服务器 ID 由地址派生**（`Store.getServerId`），改服务器名不影响已有进度，也不影响移动历史；
- 进度里除了 `xpointer` / `page` / `percent`，还保存 KOReader 的 `cre_dom_version`。缺了它，KOReader 会认为文档曾用旧版本打开过而强制使用最旧 DOM 版本，导致 xpointer 对不上（参见 `readerrolling.lua`）；
- 同一路径在插件 JSON 与 sidecar 都有进度时按「较新的那份胜出」合并（`main.lua:onDocSettingsLoad`）；
- 缓存文件名带哈希，不同目录的同名文件不会互相覆盖；
- 移动历史与进度是**两个独立的 JSON**（同一 `settings` 目录），形状不同、互不影响；损坏时各自备份成 `<文件名>.corrupt-<时间戳>` 再从默认结构重建。

## 排序与移动历史

### 浏览与导航（返回上一级）

浏览界面的导航栈是插件自己的 `dir_stack`（不是 `Menu` 的 `self.paths`），因为 `Menu:init` 会无条件把 `self.paths` 重置为 `{}`。栈底恒为 `""`（根目录），`#dir_stack > 1` 即「当前不在根目录、可以返回」。

「返回上一级」有两个入口，都汇到同一个 `Browser:onReturn()`：

1. **置顶行 `⬆ ../`**——`buildItemTable` 在 `#dir_stack > 1` 时往 `item_table` **最前面**插入一条
   `{ text = "⬆ ../", is_go_up = true, is_folder = false, is_file = false, name = ".." }`
   （镜像布局下文案换成 `../ ⬆`，走 `BD.mirroredUILayout()` / `BD.ltr()`）。
   - `onMenuSelect`：`item.is_go_up` → 调 `onReturn()`；
   - `onMenuHold`：`item.is_go_up` → 直接 `return true`，**不弹文件管理菜单**（它没有可重命名/删除/移动的内容）；
   - 它不是文件也不是目录（`is_file` / `is_folder` 均为 `false`），因此不参与进度标记、不进 `getFileButtons` / `getFolderButtons` 分支；
   - 根目录**不插入**这一行。
2. **左下角返回箭头**（`Menu` 的 `page_return_arrow`）——它的可点性由 `Menu:updatePageInfo` 依据 `#self.paths` 决定，插件用 `Browser:syncMenuPaths()` 把 `dir_stack` 的可返回性同步过去。这是修复一个既有 bug，详见「已知问题与排障」里的对应条目。

`wdr/sort.lua` 的 `sortItems` 里，`less()` 的**第一个**判断就是 `isGoUp()`：
```lua
local ua, ub = isGoUp(a), isGoUp(b)
if ua ~= ub then return ua end      -- 置顶行恒在前
if ua and ub then return false end  -- 两个置顶行视为相等
```
这个判断**先于** `folders_first` 与主键比较，所以置顶行不受排序键、升序/降序、目录优先的任何影响，也不参与 tie-break。这是刻意的：回退入口的位置必须始终可预期，否则用户切一次排序就找不到「怎么回去」——正是最初那次用户反馈的根源。

`onReturn()` 的语义：`#dir_stack > 1` 时弹栈并重新 `enterPath`；**栈已到根（`#dir_stack == 1`）时等价于关闭浏览界面**（`onClose()`），而不是「什么都不做」——否则根目录下点返回毫无反馈，用户会以为按钮坏了。

### 排序（`wdr/sort.lua` + `wdr/browser.lua`）

`wdr/sort.lua` 是纯数据层，不 require 任何 UI 模块（`gettext`、`ffi/util.strcoll` 都用 `pcall` 兜底），因此桌面 Lua 5.1 单测可直接 `require`。它导出：

- `Sort.keys`：有序数组，元素 `{ key=, text=, descending=, date_based= }`，顺序固定为
  `name` / `name_natural` / `modified` / `created` / `size` / `type`；
- `Sort.resolve(key)` / `Sort.getText(key)`：未知键回退 `Sort.DEFAULT_KEY`（`"name"`）；
- `Sort.sortItems(items, opts)`：对 `browser.lua` 构造好的菜单项数组做**原地**排序。

实现要点：

- **置顶的导航行**。`is_go_up` 的「返回上一级」行恒在最前，先于 `folders_first` 与主键比较（细节见上一节）。
- **纯本地重排**。`browser.lua` 把 `client:list()` 的原始结果留在 `self.raw_items`，切排序时走 `applySort()` → 用 `raw_items` 重建 `item_table`，**不重新请求服务器**（切换排序没有网络开销）。重建时会重新插入置顶行，所以排序切换后它仍在第一行。
- **方向语义**。`opts.descending` 是「用户视角的真实方向」（`false` 升序 / `true` 降序）；每个键另有内建自然方向 `spec.descending`（`modified`、`created` 为 `true`，即新→旧），两者不一致时内部才取反。因此 UI 上显示的箭头始终等于用户看到的真实顺序。
- **目录优先与目录排序**。`opts.folders_first`（默认 `true`）时目录整块在前；**目录之间永远按名称比较**，方向跟随 `descending`——所以日期/大小键下目录不会因为「没有 modification/filesize」被甩到文件后面。`folders_first=false` 时目录与文件混排，全部按主键比较。
- **缺值处理**。日期键下缺 `modification` / `created` 的项**始终排最后**，与 `reverse` 无关（比较前先按「有没有值」分组，保证比较器满足 `table.sort` 的严格弱序）；`size` 键下缺大小按 `0`；`type` 键按小写扩展名比较，无扩展名视为 `""`。
- **确定性**。主键相等时依次按名称（**始终升序**，方向只属于主键）、再按 `text` 做 tie-break，结果与 `table.sort` 的实现无关。
- **日期显示**。`Sort.KEY_BY_ID[key].date_based` 为真时，`buildItemTable` 在文件行的 `mandatory` 里加一段 `os.date("%Y-%m-%d", stamp)`，供用户核对排序结果。

排序偏好写进插件状态 `webdavreader_state.lua` 的 `sort_key` / `sort_descending` / `sort_folders_first`（`main.lua` 的 `saveSortSettings`）。**这是全局一份**，所有服务器、所有目录共用同一套排序偏好——不存在「按目录分别记住排序」的行为。`browser.lua` 不直接碰持久化，而是通过构造参数 `on_sort_changed` 回调插件，值未变化时不会重复回调。

`DAV:creationdate` 是 WebDAV 的**可选**属性，不少服务器（部分 NAS、某些 Nextcloud 配置）不返回；另有一小撮严格/简陋的实现甚至不接受这个属性，会直接对整条 PROPFIND 回 `400/403/409/500`（RFC 4918 要求逐属性返回 404，但现实并不总是如此）。

因此 `wdr/webdav.lua` 准备了两套请求体：

- `PROPFIND_BODY`：带 `<d:creationdate/>`（首次请求用）；
- `PROPFIND_BODY_BASIC`：只有 `resourcetype` / `getcontentlength` / `getlastmodified`。

`Client:list` 首次带 creationdate 请求，若得到**任何非 207** 的响应，就自动用基础体重试一次，并在该 client 实例上记住 `_no_creationdate`（同一服务器的后续请求直接走基础体，不再多花一次往返）。`Client:exists` 同理（`404` 视为正常的「不存在」，不触发重试）。

**即使服务器完全不支持 `DAV:creationdate`，目录浏览也不受影响**——只是所有文件都拿不到 `created`，于是「创建时间」排序会把它们全部当成「无日期」而排在最后（组内按名称兜底），表现为「按创建时间排了好像没排」。同理，`webdav.lua` 解析时**绝不用 `getlastmodified` 冒充** `created`。这两点都是预期行为，不是 bug。

### 移动位置历史（`wdr/history.lua`）

`wdr/history.lua` 同样是纯逻辑层，落盘走 `Store.newJsonStore`（懒加载 / `dirty` / 损坏备份语义与进度存储一致）：

- 每个服务器一份 MRU 列表，键为 `Store.getServerId(server)`（地址派生），上限 `History.DEFAULT_LIMIT = 20`，超出淘汰最旧的一条；
- `History:add(server, dir)` 用 `Store.normalizeDir` 归一化（`""` = 根目录，是合法记录），同目录再次 add 只更新 `used` 并 `count+1`、提到数组首位，然后立即 flush；
- `History:list(server, limit)` 按 `used` 倒序返回（同一秒内多次 add 时按磁盘数组顺序兜底，结果确定）；
- `History:remove` / `History:clear` 只动这份快捷位置记录，**不碰服务器文件，也不碰进度**。

界面侧两处消费：`browser.lua:showMoveDialog` 取最近 `MOVE_HISTORY_LIMIT = 8` 条（过滤掉与当前目录相同的条目）作为一键移动按钮；`main.lua:showMoveHistory` 按服务器分组列出全部记录，支持逐条移除与「清空全部移动记录」。只有在 `manager:moveItem` 成功之后 `browser.lua:doMove` 才 `History.add`，失败的目标不会被记住。

## 开发与测试

`tools/lua`、`tools/luac` 是为本项目编译的 Lua 5.1（与 KOReader 的 LuaJIT 语法基线一致），是 **Linux x86_64 二进制**，Windows 上无法直接运行，需要在 Linux/WSL 里跑：

```bash
cd <repo>

# 全部单元测试（11 个套件，应全部通过）
./tools/lua tests/run_all.lua

# 单个套件
./tools/lua tests/run_all.lua progress
./tools/lua tests/run_all.lua sort history
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

- `内部存储/koreader/plugins/webdavreader.koplugin/` 下 13 个文件（`_meta.lua`、`main.lua`、`wdr/` 11 个）；
- 重启后 `koreader/settings/webdavreader.lua` 会被创建（说明插件已加载、配置入口可用）；
- 若点击菜单崩溃，先按[兼容性](#兼容性)确认 KOReader 版本。

## 已知问题与排障

| 现象 | 原因 / 处理 |
|---|---|
| 点击「浏览远程文件」KOReader 崩溃 | KOReader 正式版缺少 `BookList.getCollateSortFunc`，升级到 nightly 即可 |
| 左上角没有菜单按钮（于是打不开排序） | `title_bar_left_icon` 必须由 `main.lua:openBrowserFor` 作为**构造参数**传给 Browser；`Menu:init` 靠它决定是否创建左按钮，事后在 `Browser:init` 里调 `setTitleBarLeftIcon` 已经晚了（那时 `title_bar` 还是 nil） |
| 左下角返回箭头点了没反应 | **既有 bug，非新功能引入**：`Menu:updatePageInfo`（KOReader `menu.lua:1064`）用 `self.page_return_arrow:enableDisable(#self.paths > 0)` 决定箭头可点性，而插件导航用独立的 `dir_stack`、从不写 `self.paths`（`Menu:init` 还会把它重置为 `{}`），于是箭头恒处于 disabled。修复：`Browser:syncMenuPaths()` 把 `dir_stack` 的可返回性同步给 `self.paths`（与官方 `filemanagercollection.lua:109` 同一手法），并在回根时清空 |
| 点「阅读进度记录」或「移动位置记录」里的条目后 KOReader 崩溃 | **既有 bug**：`main.lua` 顶部有 `local _ = require("gettext")`，而 `for _, x in ipairs(...)` 把 `_` 遮蔽成 ipairs 的索引（数字）；延迟执行的闭包里再调 `_("...")` 就抛 `attempt to call local '_' (a number value)`。`browser.lua` 目录回退分支、`history.lua:clear` 同样问题。已修复（循环变量改名 `entry_idx` / `server_idx` / `srv_idx` / `srv_id` / `candidate_idx` / `item_idx` / `info_idx` / `key_idx` 等）。若再次出现，检查新写的循环是否又用 `_` 作占位变量 |
| 重新打开服务器后，明明在深层目录却没有返回入口（箭头灰、无 `⬆ ../`、菜单「上一级」灰） | **既有 bug**：恢复「上次浏览位置」时只调了 `enterPath`，`dir_stack` 仍停在 `{ "" }`，于是 `#dir_stack > 1` 的三处判据全为假；更糟的是 `onReturn()` 会走 `onClose()`，在深层目录按返回直接关掉界面。修复：新增 `Browser:rebuildDirStack(path)`（按路径段逐级压栈，`books/deep` → `{"", "books", "books/deep"}`）与 `Browser:openPathAt(path, do_show)`，`main.lua:openBrowserFor` 改用 `openPathAt`，`enterPath` 的回退分支与 `openServer` 也同步重建栈。若出现，检查是否有新的「直接跳到某个路径」的代码路径漏了重建栈 |
| TXT 里换字体不生效 | KOReader 对 TXT 默认用等宽字体渲染，与插件无关；开启「设置 → 样式 → 自动检测 TXT 文件排版」解决（上游 [koreader#13349](https://github.com/koreader/koreader/issues/13349)） |
| 移动文件报 `HTTP 502 Source and destination must have the same host name` | 某些严格实现（wsgidav）对 `Host` 头敏感；插件已显式发送带端口的 `Host`，若仍出现请核对地址中的端口 |
| 移动报「目标已存在」 | 有意设计：MOVE 带 `Overwrite: F`，不会静默覆盖 |
| 删除目录提示超过 8 层 / 2000 项 | 递归删除的安全阀，防止误删超大目录 |
| 从 KOReader 历史记录打开缓存文件，进度对应不上 | 需要 `webdavreader_state.lua` 里的本地路径映射；清过缓存后需重新从远程浏览界面打开 |
| 「创建时间」排序后大量文件堆在最后 | 服务器没返回 `DAV:creationdate`（该属性是可选），这些项按预期排在最后、组内按名称兜底；改用「修改时间」排序 |
| 服务器直接拒绝带 creationdate 的 PROPFIND | 已自动降级：`Client:list` 收到非 207 后改用基础请求体重试并记住该服务器，目录浏览不受影响 |
| 移动历史里的目标目录已失效（改名/删除） | 主菜单 → WebDAV 远程阅读 → 移动位置记录，逐条移除或清空；只影响快捷位置，不动服务器文件 |
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
| 未发版 | 目录排序（6 种排序键 + 升降序 + 目录优先，选择会记住）与移动位置历史（每服务器 20 条 MRU） |
