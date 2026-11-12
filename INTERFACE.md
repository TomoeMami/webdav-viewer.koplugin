# 模块接口契约（内部约定，改接口前必须先改本文件）

插件名：`webdavreader.koplugin`
目标 KOReader：2023.10 及以后（依赖 `ui/widget/menu`、`luasettings`、`socketutil`、`ffi/sha2`、`document/documentregistry`）

```
webdavreader.koplugin/
  _meta.lua              插件元信息
  main.lua               插件入口（WidgetContainer）：菜单注册、事件钩子、调度
  wdr/
    json.lua             JSON 编解码（纯 Lua，已完成）
    store.lua            路径键 / 进度存储 / 通用 JSON 存储 / 缓存名（纯逻辑，已完成）
    webdav.lua           WebDAV 协议客户端（纯网络层，无 UI）
    config.lua           多服务器配置读写（LuaSettings 封装）
    cache.lua            临时目录下载 / 校验 / 清理
    progress.lua         进度桥接（doc_settings <-> 插件 JSON）
    sort.lua             目录排序（纯数据层：排序键、方向、目录优先）
    history.lua          移动位置历史（每服务器 MRU 列表，纯数据层）
    browser.lua          远程浏览界面（Menu 子类）
    manager.lua          远程文件管理操作（删除 / 移动 / 新建目录）
  tests/                 run_tests.lua 与各模块单测（桌面 Lua 5.1 运行）
  docs/                  使用说明
```

## 全局规约

1. **所有模块返回单例 table**，方法用 `:` 调用；构造型函数显式返回新对象。
2. 网络层**绝不弹 UI**。所有错误以 `nil, err_message` 形式返回；`err_message` 为可直接展示给用户的英文短句。
3. UI 层**绝不直接拼 HTTP**，一律经 `wdr/webdav`。
4. 所有面向用户的字符串用 `_()` 包裹（`require("gettext")`）。
   **不要用 `_` 当循环占位变量**（`for _, x in ipairs(...)`）：这些文件顶部就是
   `local _ = require("gettext")`，遮蔽后同/内层作用域里的 `_("...")` 会变成
   「调用数字」，抛 `attempt to call local '_' (a number value)`。用
   `for entry_idx, x in ipairs(...)` 之类的具名变量。
5. Lua 5.1 语法（无 `goto`、无位运算符、无 `#` 作用于稀疏表）。KOReader 的 LuaJIT 兼容 5.1。
6. 禁止 `os.execute` / `io.popen`。
7. 文件读写一律显式 `close()`；网络请求后必须 `socketutil:reset_timeout()`。

## wdr/webdav.lua（网络层）

```lua
local WebDAV = require("wdr.webdav")

-- 绑定一个服务器配置，返回客户端对象（不修改传入 table）
-- server: { address=, username=, password=, start_dir= }
-- opts:   { timeout_block=, timeout_total= } 可省略
local client = WebDAV.client(server, opts)

-- 列出目录。path 为相对路径（可为 "" 表示根）
-- 返回：items, err
--   items = { { name=, is_folder=, size=, modified=, created=, path= }, ... }
--     name     : 文件名/目录名（已 urlDecode，UTF-8）
--     path     : 相对路径（不含服务器前缀、不含前导 /）
--     modified : unix 秒数，可能为 nil
--     created  : DAV:creationdate 解析出的 unix 秒，可能为 nil（**不会**用 modified 冒充）
--   err = nil | string
-- 只返回当前目录的直接子项，不含自身。服务器返回 207 之外视为错误。
-- 服务器拒绝 creationdate 时会自动用基础请求体重试（见下方 parseMultiStatus 约定）。
function client:list(path)

-- 下载到本地文件，返回 ok, err
-- opts.progress_cb  : function(downloaded, total) （total 可能为 nil）
function client:download(path, local_path, opts)

-- 上传本地文件到远程路径（PUT），返回 ok, err
function client:upload(local_path, remote_path)

-- 删除文件或目录，返回 ok, err
function client:delete(path)

-- 移动/重命名，返回 ok, err
-- 目标已存在时要求服务器拒绝（MOVE 不加 Overwrite 头以外的覆盖语义）
function client:move(from_path, to_path)

-- 新建目录，返回 ok, err
function client:mkdir(path)

-- 探测路径是否存在，返回 exists(bool), is_folder(bool|nil), err
function client:exists(path)

-- 原始请求（调试用），返回 ok, status_code, body
function client:request(method, path, opts)

-- 纯函数，供单测：URL 拼接与 XML 解析
WebDAV.joinUrl(address, path, { trailing_slash = true })
WebDAV.parseMultiStatus(xml, options)
WebDAV.getHostHeader(address)        --> "host:port"|nil   （见下方 Host 头说明）
WebDAV.parseHttpDate(str)            --> unix 秒|nil
WebDAV.setDependencies(deps)         --> 仅测试用，生产代码不要调用
```

`parseMultiStatus` 约定：
- `options.self_href`：用于剔除 PROPFIND 返回的目录自身条目
- `options.self_path` / `options.address` / `options.dir`：可选扩展，剔除自身更可靠；
  只传 `self_href` 也能正常工作
- 返回 `{ { name=, is_folder=, size=, modified=, created=, href=, path= }, ... }, err`
  （`path` 为相对路径，是契约的超集；`href` 为服务器原始 href）
- `created` 来自 `DAV:creationdate`（RFC 3339，带 `Z` 或时区偏移都要能换算成 UTC unix 秒）；
  服务器没返回、元素为空、文本非法时一律为 `nil`，**绝不用 `modified` 冒充**。
  `PROPFIND` 请求体必须包含 `<d:creationdate/>`。
- **必须能降级**：首次 `list` 带 creationdate 请求，若响应不是 207，改用不含该属性的
  基础请求体重试一次，并在 client 实例上置 `self._no_creationdate = true`（之后同一服务器
  直接走基础体）。`exists` 同理，但 `404` 是正常的「不存在」，不触发重试。
  原因：`DAV:creationdate` 是可选属性，极少数严格实现会因不认识的属性对整条 PROPFIND 报错，
  而「创建时间排序」绝不能连累目录浏览。降级后 `created` 全为 `nil`，由排序层排到最后。
- 必须容忍：`<d:` `<D:` `<lp1:` `<ns0:` 等任意命名空间前缀、无前缀默认命名空间、
  自闭合标签、属性顺序变化、元素顺序变化、注释、CDATA
- 必须对 `href` 先解 XML 实体再 urlDecode

**Host 头（重要）**：luasocket 的 `socket.http` 默认发 `Host: <host>` 会丢掉非默认端口，
导致严格实现的服务器（如 wsgidav）在 MOVE 时返回 502
"Source and destination must have the same host name"。
因此 `Client:_perform` 必须显式设置带端口的 `Host` 头；`WebDAV.getHostHeader`
负责从地址推导（默认端口 80/443 时省略端口）。

## wdr/store.lua（键与存储底层）

```lua
local Store = require("wdr.store")

-- 键与路径工具（纯函数）
Store.shortHash(s)                        --> 12 位十六进制短哈希
Store.getServerId(server)                 --> 服务器 ID（由 address 派生；改名不变）
Store.normalizeDir(path)                  --> 去掉首尾/重复斜杠；根目录返回 ""
Store.getRemoteKey(server, remote_path)   --> "<服务器ID>/<相对路径>"
Store.splitRemoteKey(key)                 --> server_id, rel_path
Store.getRemoteFileName(remote_path)      --> 文件名
Store.getRemoteDir(remote_path)           --> 所在目录（无前导斜杠）
Store.joinRemotePath(dir, name)           --> 拼接（仅归一化）
Store.getCacheFileName(server, remote_path) --> 扁平缓存文件名
Store.getServerIdFromCacheName(name)      --> 由缓存文件名反查服务器 ID

-- 通用 JSON 文档存储（wdr/history.lua 用它落盘；进度用 ProgressStore，两者互不影响）
local store = Store.newJsonStore{
    path = <json 文件绝对路径>,
    default_data = function() return tbl end,   -- 可选，缺省 {}
    readfile = function(path) ... end,          -- 可选，注入测试
    writefile = function(path, content) ... end,-- 可选
    encode = function(tbl) ... end,             -- 可选（也可稍后 setCodec 注入）
    decode = function(str) ... end,             -- 可选
}
store:load()          --> ok   懒加载；文件不存在/为空 -> true；无 path/无 decoder/损坏 -> false
store:getData()       --> table（永远不是 nil；加载失败时是 default_data 的副本）
store:setData(tbl)    --> table  整体替换并置 dirty
store:markDirty()
store:isDirty()       --> bool
store:flush()         --> ok, err   err 为 "no path" / "no encoder" / "decode blocked: ..." / 编码或写入错误
store:flushIfDirty()  --> ok, err   只在 dirty 时写
store:setCodec(encode, decode)
```

关键约定（与 `ProgressStore` 对齐）：

- 构造时**不做任何 IO**，第一次 `load()` / `getData()` 才读盘，且只读一次；
- 绝不抛错，所有失败用返回值表达；
- 损坏的 JSON 先备份成 `<path>.corrupt-<时间戳>`，再从 `default_data` 重建，避免用户记录被静默清空；
- `load()` 判定「不能安全覆盖磁盘内容」时（无 decoder / 读取异常）内部置位，`flush()` 之后会拒绝写入而不是拿默认数据冲掉原文件；
- 改动 `getData()` 返回的 table 后，调用方必须 `markDirty()`。

## wdr/config.lua（配置）

```lua
local Config = require("wdr.config")

-- 单例，路径固定在 DataStorage:getSettingsDir().."/webdavreader.lua"
Config:load()
Config:getServers()            --> array of server table（浅拷贝，可安全读取）
Config:getServer(idx)          --> server|nil
Config:addServer(server)       --> idx
Config:updateServer(idx, server) --> ok
Config:removeServer(idx)       --> ok（同时删除属于该服务器的进度，由 main 协调）
Config:getDefaultServerIndex() --> idx|nil
Config:setDefaultServerIndex(idx)
Config:save()                  --> flush 落盘
Config:getProgressPath()       --> 进度 JSON 绝对路径
Config:getHistoryPath()        --> 移动位置历史 JSON 绝对路径（settings 目录下 `webdavreader_history.json`）
Config:getCacheDir()           --> 临时缓存目录绝对路径
Config:getMaxCacheMB()         --> number
Config:setMaxCacheMB(n)
Config.HISTORY_FILE            --> "webdavreader_history.json"（常量）
Config.ensureDir(dir)          --> ok（递归创建目录，供各 JSON 存储初始化用）

-- server 字段
-- { name=, address=, username=, password=, start_dir="/", verify_ssl=true }
```

## wdr/cache.lua（临时缓存）

```lua
local Cache = require("wdr.cache")

Cache:setDir(dir)
Cache:getLocalPath(server, remote_path)   --> 本地绝对路径（不保证存在）
Cache:isFresh(server, remote_path, remote_size, remote_mtime) --> bool 本地存在且大小（与记录过的远端修改时间）一致
Cache:invalidate(server, remote_path)
Cache:prune(max_mb)                       --> 删除最旧文件直到低于上限
Cache:sizeBytes()                         --> number
Cache:clear()                             --> ok, err
Cache:listEntries()                       --> { { name=, size=, mtime=, server_id= }, ... }
```

## wdr/progress.lua（进度桥接）

```lua
local Progress = require("wdr.progress")

Progress:setPath(json_path)
Progress:init(json_path)                  -- 幂等初始化；不传则用 Config:getProgressPath()
Progress:getKey(server, remote_path)      --> 键字符串（转发 store.getRemoteKey）
Progress:get(server, remote_path)         --> entry|nil
Progress:save(server, remote_path, entry) --> ok
Progress:remove(server, remote_path)
Progress:rename(server, old_path, new_path)   -- 注意：3 参数，单服务器
Progress:removeServer(server)             --> number 删除条数
Progress:list()                           --> array { key=, entry= }
Progress:flush()

-- 从 ReaderUI 的 doc_settings 抽取进度
Progress:extractFromDocSettings(doc_settings) --> entry|nil
-- { percent=, xpointer=, page=, total_pages=, cre_dom_version= }
-- 注意：cre_dom_version 必须采集，否则 KOReader 在缺少该字段时会强制用最旧 DOM 版本，
-- 导致 xpointer 对不上（readerrolling.lua:172-184）。
Progress:applyToDocSettings(doc_settings, entry) --> ok   写入 last_xpointer/last_page/percent_finished/cre_dom_version
```

## wdr/sort.lua（排序）

纯数据层：不 require 任何 UI / KOReader 版本相关模块（`gettext`、`ffi/util.strcoll` 均 `pcall` 兜底），桌面 Lua 5.1 可直接 `require`。

```lua
local Sort = require("wdr.sort")

Sort.DEFAULT_KEY          --> "name"（未知键的回退值）
Sort.keys                 --> array，顺序固定为
                          --   name / name_natural / modified / created / size / type
                          -- 元素字段：{ key=, text=, descending=, date_based= }
                          --   text       : 面向用户的中文文案（已过 gettext）
                          --   descending : 该键的内建自然方向；modified / created 为 true（新→旧）
                          --   date_based : true 表示列表右侧应显示日期而非大小
Sort.KEY_BY_ID            --> map: key -> 上面的元素（只读，不要改里面的字段）

Sort.resolve(key)         --> 合法 key（key 为 nil / 非字符串 / 未知值时返回 DEFAULT_KEY，不抛错）
Sort.getText(key)         --> 显示文案（未知键回退 name 的文案）

Sort.sortItems(items, opts) --> items（**原地**排序后返回同一个 table；items 非 table 时返回新的空表）

-- opts = {
--   key           = 上面 6 个 key 之一；未知值由 Sort.resolve 回退 "name"，
--   descending    = boolean|nil 用户视角的真实方向（false=升序、true=降序）；
--                   省略时使用该键的内建方向（modified / created 为新→旧），
--   folders_first = boolean|nil 目录优先，默认 true，
-- }

-- 比较函数（公开，可直接调用；参数是 item 表，全部 nil 安全）
Sort.compareStrings(s1, s2)        -- s1 < s2 时为 true；nil 视为 ""
Sort.compareNames(a, b)            -- name 字典序（缺 name 回退 text）
Sort.compareNamesNatural(a, b)     -- 自然排序：数字段按数值（"a2" < "a10"）
Sort.compareModified(a, b)         -- **新的在前**（a.modification > b.modification）
Sort.compareCreated(a, b)          -- 同 compareModified，但只看 created
Sort.compareSize(a, b)             -- a.filesize < b.filesize；nil 视为 0
Sort.compareTypes(a, b)            -- 先比小写扩展名，相同再比名称
```

item 字段约定（由 `browser.lua:buildItemTable` 构造）：

```
文件：{ text=, name=, is_folder=false, is_file=true, remote_path=, filesize=, modification=, created= }
目录：{ text=, name=, is_folder=true, is_file=false, remote_path= }
置顶：{ text="⬆ ../", name="..", is_go_up=true, is_folder=false, is_file=false, remote_path=<上一级> }
      -- 仅在 #dir_stack > 1（非根目录）时插入，恒在最前
```

比较函数返回 `true` 表示「a 应排在 b 前面」，相等返回 `false`。`compareModified` / `compareCreated` 是**内建新→旧**的比较器，`sortItems` 在需要时自行取反（`reverse = (descending ~= spec.descending)`），调用方不要自己去反转。

`sortItems` 行为契约（`browser.lua` 与单测都依赖）：

- **`is_go_up` 优先级最高**：`is_go_up` 的「返回上一级」行恒排最前，判断在 `folders_first` 与主键比较**之前**；两个 `is_go_up` 项视为相等。它不受排序键、`descending`、`folders_first` 影响，也不参与 tie-break。
- `folders_first`（默认 true）：目录整块排在文件前面；
- **目录之间永远按名称**（`compareNames`），方向跟随 `descending`，日期/大小键下不会因缺字段被甩到文件后面；
- 文件按 `key` 比较；**主键相等时**依次按名称（**始终升序**，方向只属于主键）、再按 `text` 做 tie-break，结果确定；
- 日期键下缺 `modification` / `created` 的项**始终排最后**，与 `reverse` 无关；
- `folders_first=false` 时目录与文件混排；日期键下目录没有日期，归入「缺值组」排在最后（避免拿目录名和文件日期比较这种非传递排序）；
- `size` 键下 nil 大小按 0；`type` 键下无扩展名视为 `""`（排在带扩展名之前）；
- 字段缺失、`items` 为 nil、`opts` 为 nil 都不抛错。

## wdr/history.lua（移动位置历史）

纯数据层，落盘走 `Store.newJsonStore`；按服务器隔离（键为 `Store.getServerId(server)`，地址派生）。

```lua
local History = require("wdr.history")

History.DEFAULT_LIMIT     --> 20（每个服务器最多保留条数）

-- 初始化（幂等）。不传 path 时用 Config:getHistoryPath()；path 不变则复用现有 store，不重新读盘。
History:init(json_path)                 --> History 自身

-- 记录一次成功移动的目标目录
--   dir 允许 ""（根目录）、允许带前导/尾随斜杠，内部用 Store.normalizeDir 归一化
--   同 dir 再次 add：只更新 used、count+1，并提到数组首位（MRU）；超上限淘汰最旧的一条
--   加完立即 flush
History:add(server, dir)                --> ok, entry|nil, err|nil
                                        --   entry = { dir=, used=, count= }

-- 列出某服务器的历史目录，按 used 倒序（最近用的在前）
-- 同时支持点号与冒号两种调用：History.list(server, limit) / History:list(server, limit)
-- limit 默认 DEFAULT_LIMIT；server 为 nil / 未初始化时返回空数组（永不为 nil）
History.list(server, limit)             --> array of { dir=, used=, count= }

History:remove(server, dir)             --> boolean 是否真的删到了记录（归一化后比较）
History:clear(server)                   --> number 删除条数；server 为 nil 表示清空全部服务器
History:flush()                         --> ok, err
History:getPath()                       --> string|nil 当前 JSON 路径

-- 纯函数（无 IO，UI 用来生成文案）
History.formatDir(server, dir)          --> "/" 或 "/"..dir（不带尾斜杠）
History.formatLabel(entry)              --> 形如 "/books/done   3 次"；count<=1 时不显示次数，空记录返回 ""

-- 仅测试用，生产代码不要调用
History:_setStoreForTest(store, path)
History:_setNowForTest(fn)              --> 注入时钟，避免依赖 os.time() 秒级粒度
```

存储格式（version 1，与进度 JSON 各自独立）：

```json
{ "version": 1,
  "servers": { "<server_id>": [ { "dir": "books/done", "used": 1700000000, "count": 3 } ] } }
```

约定：

- `dir == ""` 表示根目录，是合法且有价值的记录；
- `used` 为最后使用时间（`os.time()` 秒），`count >= 1`；
- 记录里**只有目标目录**（`dir`），不记录来源目录，也不记录文件名；
- 数据损坏时整份备份成 `<path>.corrupt-<时间戳>` 并从 `{ version = 1, servers = {} }` 重建，绝不抛错；
- `remove` / `clear` 只影响这份快捷位置记录，**不碰服务器文件，也不碰阅读进度**；
- 这是一份纯本地的 JSON，**没有任何跨设备同步**；
- 浏览器只在 `manager:moveItem` 成功后才调用 `add`。

## main.lua 暴露给内部模块的接口

```lua
-- 插件实例 self 上的方法，browser.lua 通过 self.plugin 回访：
plugin:getClientFor(server)       --> webdav client（带缓存，同一服务器复用）
plugin:openRemoteFile(server, item, local_path) --> 登记 Session 并用 KOReader 打开
plugin:resolveRemoteFor(doc_file)  --> 由本地路径反查远程上下文（保存/恢复共用同一入口）
plugin:saveCurrentProgress(reason) --> 抽取并落盘进度
plugin:saveSortSettings(key, descending, folders_first)
                                   --> 把排序偏好写进 webdavreader_state.lua
                                       （sort_key / sort_descending / sort_folders_first，key 经 Sort.resolve 兜底）
plugin:showMoveHistory()           --> 「移动位置记录」界面：按服务器分组列出、逐条移除、清空全部
plugin:openBrowserFor(server_idx)  --> 创建 Browser，并用状态文件里的排序偏好初始化它

排序状态的传递方式：plugin:openBrowserFor 把 sort_key / sort_descending / sort_folders_first
作为构造参数传给 Browser，同时注入回调 on_sort_changed(key, descending, folders_first)；
Browser 排序变化时只回调，不自己碰持久化（界面层与存储层解耦）。

Browser 的两个路径入口（都在 browser.lua 上，main.lua 负责选择用哪个）：
  browser:enterPath(path, do_show)   --> 只换内容，**不动 dir_stack**
  browser:rebuildDirStack(path)      --> 按路径段重建 dir_stack，返回重建后的栈
                                        （"" -> {""}；"books/deep" -> {"", "books", "books/deep"}）
  browser:openPathAt(path, do_show)  --> rebuildDirStack + enterPath（推荐用于「直接跳到某路径」）

  约定：凡是**不经过逐级点击**就到某个路径的代码（如 openBrowserFor 恢复上次位置、
  enterPath 的失败回退、openServer），都必须走 openPathAt / rebuildDirStack，否则
  dir_stack 与 self.path 不一致，#dir_stack > 1 的三处判据（置顶 ⬆ ../、左下角箭头、
  目录菜单「上一级」）会全部失效，且 onReturn() 会误走 onClose() 关掉界面。

进度回写时机（缺一不可）：
  onDocSettingsLoad  —— 打开前按远程键恢复进度（会与 sidecar 比较，进度靠后者胜出）
  onSaveSettings     —— Reader 保存设置时
  onCloseDocument    —— 关书时（并决定是否清缓存 / 返回列表）
  onFlushSettings    —— 插件收到 FlushSettings 时
  onPageUpdate       —— 每 10 页触发一次快照（60 秒节流）
  onPosUpdate        —— 滚动模式，60 秒节流
为什么需要后两者：KOReader 的自动保存默认间隔 15 分钟，不自己快照的话崩溃会丢进度。

界面层注意：
  * 左侧按钮**必须**由 `main.lua:openBrowserFor` 作为构造参数 `title_bar_left_icon = "appbar.menu"`
    传进去。`Menu:init` 正是靠这个字段决定「要不要创建左按钮」（缺省 nil 就不创建），
    事后再调 `setTitleBarLeftIcon` 也补不回来——`Browser:init` 阶段 `title_bar` 还是 nil，
    在 `Browser:init` 里调用会直接崩。图标保持汉堡菜单（`appbar.menu`），不要改成加号之类，
    否则用户会以为它是「新建」。
  * 不要用 Menu 的 self.paths 做导航（Menu:init 会无条件重置它），导航栈用独有字段 dir_stack。
    但 self.paths 本身仍要维护——`syncMenuPaths()` 只把「能不能返回」这一个布尔信息写进去，
    供 Menu 决定左下角返回箭头的可点性；它不是导航状态的来源。
  * 关书后重新打开列表必须交给 FileManager 实例（ReaderUI 没有 openFile 方法），
    通过广播 ShowWebDavReaderBrowser 事件实现。
  * 排序变化后必须**同时**刷新标题栏副标题与列表：browser 的 applySort() 已封装
    （重建 item_table → refreshTitleSubtitle → updateItems），不要只调其中一个。
  * item_table 是排序的产物，**不是**数据源；重排的数据源是 self.raw_items
    （client:list 的原始结果）。切排序不得重新请求服务器。
  * 所有排序比较规则一律放在 wdr/sort.lua，界面层不要自己写 table.sort 的比较函数。
  * `syncMenuPaths()` 必须在 `switchItemTable` **之前**调用：`switchItemTable` →
    `updateItems` → `updatePageInfo` 会读 `#self.paths` 来决定左下角返回箭头是否可点
    （KOReader `menu.lua:1064` 的 `enableDisable(#self.paths > 0)`）。晚一步调用，
    箭头就还是上一轮的禁用状态。**回根时必须把 `self.paths` 清空**（只 insert 不清理，
    回根后箭头仍可点，点了却无处可去）。
  * `buildItemTable` 会在 `#dir_stack > 1` 时于最前面插入一条 `is_go_up = true` 的置顶行
    （`text = "⬆ ../"`，镜像布局下为 `"../ ⬆"`）。该行**既不是文件也不是目录**
    （`is_file = false` / `is_folder = false`），UI 与排序逻辑都不得把它当条目处理：
    不给它挂进度、不进 `getFileButtons` / `getFolderButtons`、`onMenuHold` 直接返回。
    `wdr/sort.lua` 通过 `is_go_up` 保证它恒在最前。
```

## wdr/manager.lua（远程文件管理）

```lua
local Manager = require("wdr.manager")
local m = Manager:new{
    config = Config, progress = Progress, cache = Cache,
    get_client = function(server) ... end,
    max_depth = 8,     -- 可选，递归删除深度上限
    max_items = 2000,  -- 可选，递归删除条目上限
}
-- 或单例注入：Manager:setup{ ... }

m:deleteFile(server, remote_path)            --> ok, err
m:deleteFolder(server, remote_path)          --> ok, deleted_count, err
m:countFolderItems(server, remote_path)      --> file_count, folder_count, err
m:moveItem(server, from_path, to_path)       --> ok, err
m:renameFile(server, remote_path, new_name)  --> ok, new_path, err
m:createFolder(server, parent_path, name)    --> ok, new_path, err
m:validateName(name)                         --> ok, err      （纯函数）
m:validateMoveTarget(server, from, to)       --> ok, err
```

约定：
- 所有 client 调用都包 pcall，异常转成错误返回值，绝不冒到 UI 层。
- 递归删除是「两遍式」：先统计并生成后序序列，超限时一个都不删。
- 移动/重命名成功后迁移进度键；失败时进度与缓存保持原样。
- 错误消息格式：`"<操作名> failed: <底层错误>"`。

## 调用方向

```
main.lua ──> browser.lua ──> manager.lua ──> webdav.lua
   │              │
   │              ├──> progress.lua (读取展示) / cache.lua
   │              ├──> sort.lua (列表重排) / history.lua (移动快捷位置 + 记录)
   │              └──> config.lua (服务器与路径)
   └──> progress.lua (reader 事件钩子) / config.lua / history.lua (移动记录界面)
```
