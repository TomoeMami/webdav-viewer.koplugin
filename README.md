# WebDAV 远程阅读 — webdavreader.koplugin

在 KOReader 里浏览 WebDAV 服务器上的文件，**点开即读**：不需要先选一个本地下载目录，也不需要下载完再去文件管理器里找。阅读进度按「服务器 + 远程路径 + 文件名」保存在插件自己的 JSON 里，清缓存、重装插件、换设备都不会丢。

- 插件目录：`webdavreader.koplugin`（安装到 `koreader/plugins/` 下即生效）
- 菜单位置：**主菜单 → 搜索 → WebDAV 远程阅读**
- 许可证：[GPL-3.0-or-later](LICENSE)

> 仓库名 `webdav-viewer.koplugin` 只是项目名；KOReader 以目录名识别插件，安装目录用本文的 `webdavreader.koplugin` 即可（任何以 `.koplugin` 结尾的目录名都能被加载，改名会重置该插件的启用状态记录）。

## 基本情况

| 项目 | 说明 |
|---|---|
| 适用软件 | KOReader，**必须为 nightly（master）版本**，见[安装须知 #1](#1-必须使用-koreader-nightlymaster) |
| 适用文件 | KOReader 能打开的所有格式（txt / md / html / epub / pdf / fb2 / mobi / azw3 / cbz…） |
| 依赖 | 仅依赖 KOReader 自带模块（`luasocket`、`lfs`、`ffi`），不需要额外安装库 |
| 插件存储 | 配置 `koreader/settings/webdavreader.lua`、进度 `koreader/settings/webdavreader_progress.json`、移动位置历史 `koreader/settings/webdavreader_history.json`、缓存 `koreader/data/webdavreader_cache/` |

功能一览：

| 能力 | 说明 |
|---|---|
| 直接打开 | 点击文件即下载到临时缓存并打开，无需选择保存位置 |
| 返回上一级 | 子目录顶部置顶一行 `⬆ ../`，点一下就回上一层；也可用左下角返回箭头或长按左上角按钮 |
| 列表图标 | 目录 `▣` / 文件 `▤`（U+25A3 / U+25A4）。刻意不用 emoji 或 Nerd Font 私有区字符——KOReader 自带字体里没有那些字形，会显示成方框+问号 |
| 进度独立 | 进度存在插件自己的 JSON，按键值（服务器 + 远程路径）保存，不依赖侧车文件 |
| 缓存管理 | 容量上限 + LRU 自动淘汰，默认关闭书籍后清理该文件缓存 |
| 远程文件管理 | 删除（含目录递归）、移动、重命名、新建目录 |
| 目录排序 | 名称 / 名称（自然排序）/ 修改时间 / 创建时间 / 大小 / 类型，可升降序、可切换目录优先；选择会被记住 |
| 移动快捷位置 | 「移动」时直接选最近用过的目标目录，一键移动；也可手动输入其他位置 |
| 多服务器 | 可配置多个 WebDAV 账号，设置默认服务器 |

详细使用说明见 [USAGE.md](USAGE.md)；模块职责、依赖与排障见 [TECHNICAL.md](TECHNICAL.md)；内部接口契约见 [INTERFACE.md](INTERFACE.md)。

## 安装指南

### 前置条件

- KOReader **nightly（master 分支）**，见[安装须知 #1](#1-必须使用-koreader-nightlymaster)
- 设备能访问你的 WebDAV 服务器（同一局域网或公网均可）

### 步骤

1. 获取本仓库（`git clone` 或下载 zip）。
2. 把整个 `webdavreader.koplugin` 目录复制到 KOReader 的插件目录：

   ```
   koreader/plugins/webdavreader.koplugin/
   ```

   复制后的结构应为：

   ```
   koreader/plugins/webdavreader.koplugin/
   ├── _meta.lua
   ├── main.lua
   └── wdr/
       ├── browser.lua
       ├── cache.lua
       ├── config.lua
       ├── history.lua
       ├── json.lua
       ├── manager.lua
       ├── progress.lua
       ├── session.lua
       ├── sort.lua
       ├── store.lua
       └── webdav.lua
   ```

   > `wdr/` 子目录必须一起复制，插件的实际实现都在里面。
   > `tests/` 和 `tools/` 只用于在电脑上跑单元测试，**不要**复制进 KOReader。

3. 重启 KOReader（完全退出应用再打开）。
4. 主菜单 → **工具 → 插件管理**，确认「WebDAV 远程阅读」为启用状态（默认启用）。
5. 主菜单 → **搜索 → WebDAV 远程阅读 → 服务器设置 → 添加服务器**，填写名称、地址、账号，点「测试连接」验证后保存。
6. 主菜单 → **搜索 → WebDAV 远程阅读 → 浏览远程文件**，即可浏览和阅读。

### 没有 adb 时怎么把插件放进设备

KOReader 的数据目录在设备内部存储里，用 MTP 也能完成安装：

1. USB 连接设备，选择「传输文件」
2. 电脑上打开 `内部存储 → koreader → plugins`
3. 把 `webdavreader.koplugin` 整个文件夹拖进去
4. 在设备上重启 KOReader

## 安装须知

### 1. 必须使用 KOReader nightly（master）

插件依赖 `BookList.getCollateSortFunc`，该接口 **2026-09 才合入 KOReader master**，目前所有正式版（含最新的 v2026.07.1）都没有。用正式版会在点击「浏览远程文件」时直接崩溃。

nightly 安装方法：

1. 打开 <https://github.com/koreader/koreader/releases/tag/ota>
2. 下载对应架构的 APK（华为 / 安卓平板通常是 `koreader-android-arm64-<版本>_<日期>.apk`）
3. 覆盖安装即可，`koreader/` 目录里的书、进度、配置、插件都会保留

版本要求与崩溃原因详见 [TECHNICAL.md](TECHNICAL.md#兼容性)。

### 2. TXT 里的自定义字体不生效？

这不是插件的问题，而是 KOReader 对 TXT 的默认渲染方式：TXT 会按「预格式化」+ **等宽字体**渲染，所以「字体」菜单里选的主字体、默认字体都不生效（上游已知问题：[koreader#13349](https://github.com/koreader/koreader/issues/13349)）。

解决办法：

1. 打开任意一个 TXT 文档
2. 阅读界面 → **设置 → 样式 → 自动检测 TXT 文件排版** → 勾选（会提示重新加载文档，确认即可）
3. 想对所有 TXT 生效：在该选项上**长按**，设为全局默认（条目后出现 ★）

设置后 TXT 会按普通段落渲染，你选择的自定义字体（含默认字体）就会生效。

### 3. 缓存、进度与配置的位置

| 内容 | 路径 |
|---|---|
| 服务器配置 | `koreader/settings/webdavreader.lua` |
| 阅读进度 | `koreader/settings/webdavreader_progress.json` |
| 移动位置历史 | `koreader/settings/webdavreader_history.json` |
| 浏览状态（上次目录、排序偏好） | `koreader/settings/webdavreader_state.lua` |
| 临时缓存 | `koreader/data/webdavreader_cache/` |

清缓存不影响进度；把 `webdavreader_progress.json` 复制到另一台设备可继续阅读。缓存默认在关闭书籍后清理，可在「缓存设置」里改为保留，并设置容量上限。

### 4. 卸载

删除 `koreader/plugins/webdavreader.koplugin` 目录并重启 KOReader 即可。如需彻底清除，再删除上面表格中的配置、进度、历史、状态和缓存文件。

## 许可证

本项目以 **GPL-3.0-or-later** 发布，完整条款见 [LICENSE](LICENSE)。
