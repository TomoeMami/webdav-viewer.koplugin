-- SPDX-License-Identifier: GPL-3.0-or-later
local _ = require("gettext")
return {
    fullname = _("WebDAV 远程阅读"),
    description = _([[浏览 WebDAV 服务器上的文本文件并直接用 KOReader 阅读：
无需指定本地下载目录（自动下载到临时缓存），
阅读进度保存在本插件独有的 JSON 中（按远程路径与文件名区分），
支持远程文件的删除、移动、重命名与新建目录。]]),
}
