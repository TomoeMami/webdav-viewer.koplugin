# 模块接口契约（内部约定，改接口前必须先改本文件）

插件名：`webdavreader.koplugin`
目标 KOReader：2023.10 及以后（依赖 `ui/widget/menu`、`luasettings`、`socketutil`、`ffi/sha2`、`document/documentregistry`）

```
webdavreader.koplugin/
  _meta.lua              插件元信息
  main.lua               插件入口（WidgetContainer）：菜单注册、事件钩子、调度
  wdr/
    json.lua             JSON 编解码（纯 Lua，已完成）
    store.lua            路径键 / 进度存储 / 缓存名（纯逻辑，已完成）
    webdav.lua           WebDAV 协议客户端（纯网络层，无 UI）
    config.lua           多服务器配置读写（LuaSettings 封装）
    cache.lua            临时目录下载 / 校验 / 清理
    progress.lua         进度桥接（doc_settings <-> 插件 JSON）
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
--   items = { { name=, is_folder=, size=, modified=, path= }, ... }
--     name     : 文件名/目录名（已 urlDecode，UTF-8）
--     path     : 相对路径（不含服务器前缀、不含前导 /）
--     modified : unix 秒数，可能为 nil
--   err = nil | string
-- 只返回当前目录的直接子项，不含自身。服务器返回 207 之外视为错误。
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
- 返回 `{ { name=, is_folder=, size=, modified=, href=, path= }, ... }, err`
  （`path` 为相对路径，是契约的超集；`href` 为服务器原始 href）
- 必须容忍：`<d:` `<D:` `<lp1:` `<ns0:` 等任意命名空间前缀、无前缀默认命名空间、
  自闭合标签、属性顺序变化、元素顺序变化、注释、CDATA
- 必须对 `href` 先解 XML 实体再 urlDecode

**Host 头（重要）**：luasocket 的 `socket.http` 默认发 `Host: <host>` 会丢掉非默认端口，
导致严格实现的服务器（如 wsgidav）在 MOVE 时返回 502
"Source and destination must have the same host name"。
因此 `Client:_perform` 必须显式设置带端口的 `Host` 头；`WebDAV.getHostHeader`
负责从地址推导（默认端口 80/443 时省略端口）。

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
Config:getCacheDir()           --> 临时缓存目录绝对路径
Config:getMaxCacheMB()         --> number
Config:setMaxCacheMB(n)

-- server 字段
-- { name=, address=, username=, password=, start_dir="/", verify_ssl=true }
```

## wdr/cache.lua（临时缓存）

```lua
local Cache = require("wdr.cache")

Cache:setDir(dir)
Cache:getLocalPath(server, remote_path)   --> 本地绝对路径（不保证存在）
Cache:isFresh(server, remote_path, remote_size) --> bool 本地存在且大小一致
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

## main.lua 暴露给内部模块的接口

```lua
-- 插件实例 self 上的方法，browser.lua 通过 self.plugin 回访：
plugin:getClientFor(server)       --> webdav client（带缓存，同一服务器复用）
plugin:openRemoteFile(server, item, local_path) --> 登记 Session 并用 KOReader 打开
plugin:resolveRemoteFor(doc_file)  --> 由本地路径反查远程上下文（保存/恢复共用同一入口）
plugin:saveCurrentProgress(reason) --> 抽取并落盘进度

进度回写时机（缺一不可）：
  onDocSettingsLoad  —— 打开前按远程键恢复进度（会与 sidecar 比较，进度靠后者胜出）
  onSaveSettings     —— Reader 保存设置时
  onCloseDocument    —— 关书时（并决定是否清缓存 / 返回列表）
  onFlushSettings    —— 插件收到 FlushSettings 时
  onPageUpdate       —— 每 10 页触发一次快照（60 秒节流）
  onPosUpdate        —— 滚动模式，60 秒节流
为什么需要后两者：KOReader 的自动保存默认间隔 15 分钟，不自己快照的话崩溃会丢进度。

界面层注意：
  * Browser:init 里不得调用 setTitleBarLeftIcon —— 此时 title_bar 尚未创建（会崩）。
    左侧按钮通过构造参数 title_bar_left_icon 声明。
  * 不要复用 Menu 的 self.paths（Menu:init 会无条件重置它），导航栈用独有字段 dir_stack。
  * 关书后重新打开列表必须交给 FileManager 实例（ReaderUI 没有 openFile 方法），
    通过广播 ShowWebDavReaderBrowser 事件实现。
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
   │              └──> progress.lua (读取展示) / cache.lua
   └──> progress.lua (reader 事件钩子) / config.lua
```
