# 使用手册（USAGE）

> 安装步骤见 [README.md](README.md)；模块职责、依赖与排障见 [TECHNICAL.md](TECHNICAL.md)、[INTERFACE.md](INTERFACE.md)。

在 KOReader 里浏览 WebDAV 服务器上的文本文件，**点开就能读**——不需要先选一个本地下载目录、也不需要等它下载完再去文件管理器里找。

阅读进度保存在插件自己的 JSON 里，按「服务器 + 远程路径 + 文件名」区分，所以**清理缓存、换设备、重装插件都不会丢进度**。界面上还能直接删除、移动、重命名远程文件。

---

## 和官方「云存储」（cloudstorage）插件的区别

KOReader 自带 `cloudstorage` 插件也能连 WebDAV，但它有两个绕不开的限制，本插件就是为解决它们而做的：

| | 官方 cloudstorage | 本插件 |
|---|---|---|
| 打开文件 | 必须先选「下载目录」→ 保存 → 再到文件管理器里找 | 点一下就打开（内部下到临时缓存） |
| 进度保存 | 依赖 KOReader 的 sidecar，跟着**本地路径**走 | 存在插件独立 JSON，跟着**远程路径**走 |
| 清缓存后 | 进度丢失，需要重新翻 | 进度还在，自动回到上次位置 |
| 文件管理 | 只能删单个文件 | 删除（含目录递归）/ 移动 / 重命名 / 新建目录 |
| 缓存管理 | 需要手动清理 | 有容量上限与 LRU 自动淘汰 |

两者可以共存，互不干扰。

---

## 安装

1. 把整个 `webdavreader.koplugin` 目录复制到 KOReader 的插件目录：

   ```
   koreader/plugins/webdavreader.koplugin/
   ```

   最终结构应是这样：

   ```
   koreader/plugins/webdavreader.koplugin/
   ├── _meta.lua
   ├── main.lua
   └── wdr/
       ├── browser.lua
       ├── cache.lua
       ├── config.lua
       ├── json.lua
       ├── manager.lua
       ├── progress.lua
       ├── session.lua
       ├── store.lua
       └── webdav.lua
   ```

   > 注意：`wdr` 子目录必须一起复制，里面的文件是插件的实际实现。

2. 重启 KOReader。

3. 打开 KOReader 的「工具 → 插件管理」，确认 **WebDAV 远程阅读** 已启用（默认启用）。

4. 在主菜单 →「搜索」分类下会看到 **WebDAV 远程阅读**（FileManager 与阅读界面都有）。

---

## 快速上手

### 1. 添加服务器

主菜单 → **WebDAV 远程阅读 → 服务器设置 → 添加服务器**，填写：

| 字段 | 说明 | 示例 |
|---|---|---|
| 名称 | 自己看得懂的名字 | `我的 NAS` |
| 地址 | WebDAV 的完整地址（含协议，末尾不要斜杠） | `https://nas.local:5006/dav` |
| 用户名 | WebDAV 账号 | `alice` |
| 密码 | WebDAV 密码 | |
| 起始目录 | 进去后默认打开的目录，可留空 | `/books` |

填完可以点 **测试连接** 先验证一下，再点 **保存**。

> **关于地址**：很多 NAS 的 WebDAV 端口不是 80/443。Nextcloud 通常是 `https://域名/remote.php/dav/files/用户名`；群晖是 `http(s)://IP:5005或5006/dav`；坚果云是 `https://dav.jianguoyun.com/dav`。

### 2. 浏览与阅读

主菜单 → **WebDAV 远程阅读 → 浏览远程文件**，进入后会看到：

```
📁 子目录/             ← 点击进入
📄 三体.txt   ★42% 2.1MB   ← 点击直接读（★ 是有进度的标记）
📄 readme.md         0.5KB
```

- **点击文件**：直接下载到临时缓存并用 KOReader 打开，**不需要选保存位置**。
- **点击目录**：进入下一层。
- **左上角按钮**：打开当前目录的菜单（上一级、刷新、新建文件夹、排序、切换服务器、缓存设置）。
- **长按文件**：打开文件操作菜单（打开 / 详情 / 重命名 / 移动 / 删除）。
- **长按目录**：打开目录操作菜单（进入 / 重命名 / 移动 / 删除目录）。

### 3. 文件管理

| 操作 | 位置 | 说明 |
|---|---|---|
| 删除文件 | 长按文件 → 删除 | 会二次确认；删除后该文件的本地缓存与进度记录一并清除 |
| 删除目录 | 长按目录 → 删除目录 | 会提示目录内有多少文件/子目录；**递归删除，不可恢复** |
| 重命名 | 长按 → 重命名 | 文件或目录都可以；进度记录会自动跟着迁移 |
| 移动 | 长按 → 移动 | 输入目标目录（相对服务器根，留空=根目录） |
| 新建文件夹 | 左上角按钮 → 新建文件夹 | 在当前目录下创建 |

---

## 进度是怎么保存的（重要）

进度**不**存在 KOReader 的 sidecar 里，而是存在插件自己的文件：

```
koreader/settings/webdavreader_progress.json
```

> 进度里除了书本内定位（`xpointer` / `page` / `percent`），还会一并保存 KOReader 的 `cre_dom_version`（DOM 版本）。这是必须的：没有它，KOReader 会认为「这本书以前用旧版本打开过」而强制使用最旧的 DOM 版本，导致 xpointer 对不上、打开后跳不到正确位置。

结构如下（可以直接备份或编辑）：

```json
{
  "version": 1,
  "files": {
    "a1b2c3d4e5f6/books/三体.txt": {
      "percent": 0.42,
      "xpointer": "/body/DocFragment[3]/body/div/p[12]/text().0",
      "page": 12,
      "total_pages": 300,
      "remote_path": "books/三体.txt",
      "server_name": "我的 NAS",
      "title": "三体.txt",
      "updated": 1700000000
    }
  }
}
```

键的格式是 `服务器ID/远程相对路径`：

- **服务器ID** 由服务器**地址**派生（不是名字），所以给服务器改名不影响已有进度；
- **远程相对路径** 含文件名，所以不同目录下的同名文件互不干扰；
- 同一路径在不同服务器上也是两条独立记录。

**这意味着**：缓存被清空、插件被重装、甚至换一台设备（把 `webdavreader_progress.json` 拷过去）都能回到上次的阅读位置。

### 进度冲突的处理

如果同一个文件既被本插件打开过、又被你从本地文件管理器直接打开过，两边进度不一致时：

- 插件记录里有 `updated` 时间戳，sidecar 里也记了上次同步时间；
- 打开时**较新的那份**胜出，不会用旧进度覆盖你后来读到的位置。

---

## 缓存

远程文件下载到：

```
koreader/data/webdavreader_cache/
```

文件名是「哈希 + 原始文件名 + 扩展名」的扁平结构，所以不同目录的同名文件不会互相覆盖。

- 默认**关闭书籍后自动清理**该文件的缓存（可在「缓存设置」里改为保留）；
- 有容量上限（默认 256 MB），超出后按最久未使用自动淘汰；
- **正在阅读的文件**（30 分钟内访问过）不会被自动淘汰。

「缓存设置」里可以：

- 修改容量上限
- 立即清理全部缓存（不会影响进度和远程文件）
- 切换「阅读后保留缓存」
- 切换「关闭后返回列表」——关掉书后自动回到远程浏览界面

---

## 菜单入口一览

| 路径 | 作用 |
|---|---|
| WebDAV 远程阅读 → 浏览远程文件 | 进入浏览界面（多服务器时会先让你选） |
| WebDAV 远程阅读 → 服务器设置 | 添加 / 编辑 / 设默认 / 清空进度 / 删除服务器 |
| WebDAV 远程阅读 → 缓存设置 | 容量、清理、保留策略 |
| WebDAV 远程阅读 → 阅读进度记录 | 查看所有进度（最多显示 30 条），可一键清空 |

服务器菜单里还有个「清空进度」——只删该服务器的进度记录，不动远程文件，也不动缓存。

---

## 常见问题

**Q：连不上，提示 401？**
A：用户名或密码错了。注意有些服务（如坚果云）需要的是**应用专用密码**，不是登录密码。

**Q：连不上，提示超时或无法连接？**
A：检查地址是否完整（含 `http://` 或 `https://`）、端口是否正确、KOReader 是否已连 Wi-Fi。插件在无网络时会直接提示而不会卡住。

**Q：能浏览但点开文件失败？**
A：确认文件格式 KOReader 支持（txt / md / html / epub / pdf / fb2 / mobi / azw3 / cbz 等）。不支持的格式会提示「KOReader 不支持打开这种文件」。

**Q：移动文件报 `HTTP 502 Source and destination must have the same host name`？**
A：这是某些严格服务器（如 wsgidav）对 `Host` 头的要求。本插件已自动发送带端口的 `Host` 头，正常不会出现；若遇到，请检查服务器地址里的端口与实际是否一致。

**Q：移动时报「目标已存在」？**
A：这是有意设计的——MOVE 请求带 `Overwrite: F`，不会静默覆盖服务器上的同名文件。请换个名字或先删除目标。

**Q：删除目录时提示「超过 8 层」或「超过 2000 项」？**
A：这是递归删除的安全阀，防止误删超大目录或陷入异常递归。可以在服务器端手动处理，或分批操作。

**Q：进度没保存？**
A：进度会在这些时机写盘：Reader 保存设置时、关闭文档时、插件收到 FlushSettings 时，以及阅读过程中的定期快照（滚动模式每 60 秒最多一次；翻页模式每 10 页触发一次、同样受 60 秒节流）。

之所以要自己做快照，是因为 KOReader 默认只在「设置了自动保存间隔」时才在阅读途中保存设置——不额外做的话，一直读不关书时进度只在内存里，崩溃就会丢。

**Q：能从 KOReader 的「历史记录」直接打开之前读过的远程文件吗？**
A：可以。插件记录了「本地缓存路径 → 远程路径」的映射，从历史记录打开缓存文件时会自动按远程键恢复进度。但如果该缓存已被清理，需要重新从远程浏览界面打开。

---

## 文件说明（给想改代码的人）

| 文件 | 职责 |
|---|---|
| `main.lua` | 插件入口：菜单注册、事件钩子（进度回写）、服务器/缓存/进度界面 |
| `wdr/browser.lua` | 远程浏览界面（继承 KOReader 的 BookList） |
| `wdr/webdav.lua` | WebDAV 协议客户端（PROPFIND/GET/PUT/DELETE/MOVE/MKCOL），不依赖 UI |
| `wdr/manager.lua` | 远程文件管理操作（删除/移动/重命名/建目录），维护进度与缓存联动 |
| `wdr/progress.lua` | 进度桥接：在 KOReader 的 doc_settings 与本插件 JSON 之间转换 |
| `wdr/store.lua` | 路径键生成、进度存储的底层实现（纯逻辑，无 UI 依赖） |
| `wdr/session.lua` | 跨插件实例的会话状态（FileManager 与 Reader 各有一份插件实例） |
| `wdr/cache.lua` | 临时缓存：路径生成、新鲜度判断、LRU 淘汰 |
| `wdr/config.lua` | 服务器配置读写、各类路径 |
| `wdr/json.lua` | 轻量 JSON 编解码（不依赖 cjson，便于单测） |

### 开发与测试

仓库自带一套桌面 Lua 工具，可直接在电脑上跑测试，不需要 KOReader：

```bash
cd koreader-plugin

# 全部单元测试（当前 460 个断言）
./tools/lua tests/run_all.lua

# 单个套件
./tools/lua tests/run_all.lua progress
./tools/lua tests/run_all.lua json store

# 语法检查
./tools/luac -p webdavreader.koplugin/main.lua
for f in webdavreader.koplugin/wdr/*.lua; do ./tools/luac -p "$f" || echo "FAIL $f"; done
```

端到端测试需要一台真实 WebDAV 服务器：

```bash
# 用 wsgidav 起一个（需要 python + wsgidav）
pip install wsgidav cheroot
python3 /tmp/wdav_server.py          # 监听 127.0.0.1:18080，根目录 /tmp/wdav_root
./tools/lua tests/test_integration.lua
```

服务器探不通时集成测试会自动 SKIP，不会报失败。

`tools/` 里的 `lua` / `luac` 是为本项目编译的 Lua 5.1（与 KOReader 的 LuaJIT 语法基线一致），`lfs.so` 与 `luasocket/` 是测试用的原生模块，**只有跑测试才需要，不要复制进 KOReader**。

各模块的接口约定见 [INTERFACE.md](INTERFACE.md)。
