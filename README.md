# Dream Manga Reader

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Build & Release](https://github.com/TypeDreamMoon/DreamMangaReader/actions/workflows/release.yml/badge.svg)](https://github.com/TypeDreamMoon/DreamMangaReader/actions/workflows/release.yml)

跨平台漫画、小说与番剧阅读器 · **Android + Windows(同等对待)**,用 **Flutter + Material 3** 构建。

## 特性

- **可插拔脚本源引擎(QuickJS via flutter_js)** —— 源用 `prepare*/handle*` 契约描述请求、宿主执行 I/O,纯函数、可沙箱化、跨平台、可远程热更。**引擎不内置任何具体源**。
- **运行时加载源** —— 启动时从外部清单(`index.json` + 脚本)加载,支持仓库 URL / 本地目录 / 磁盘缓存(离线可用);未配置时书架显示引导。见「设置 › 源管理」。
- **通用「源登录」** —— 需账号的源在脚本里实现 `prepareLogin/handleLogin`,引擎只做通用登录 UI + 按源 token 存储,不感知具体站点。
- **阅读器** —— 条漫 / 翻页 / 双页 / RTL(日漫),双档预载、无缝续章、点击与滑动翻页、亮度与缩放、阅读进度。
- **小说** —— 外部多源发现 / 搜索 / 详情 / 目录 / 正文,独立书架、历史、阅读设置和离线下载;支持导入本地 TXT 与无 DRM 的流式 EPUB。
- **书架 / 发现 / 下载 / 设置** —— 收藏与历史、离线下载与离线阅读、毛玻璃导航、封面 Hero、入场与滚动动画。
- **三主题** OLED / Dark / Light,UI 缩放,系统字体(桌面 GDI 枚举),代理设置(FlClash 兼容),备份导入导出,自动检查更新。

## 源仓库

引擎本身**零内置源**。要浏览内容,需提供一个源清单:

- **URL 方式**:在「设置 › 源管理 › 源仓库」填入 `index.json` 所在目录的 raw 根地址,App 拉取并缓存。
- **本地目录**:选一个包含 `index.json` 的文件夹。
- **桌面开发**:把清单与脚本放到仓库根的 `sources_local/`(已 gitignore),启动自动加载。

清单格式:

```json
{ "schema": 1, "sources": [
  { "id": "foo", "name": "示例小说源", "kind": "novel", "experimental": true,
    "useWebView": false, "imageReferer": "https://example/", "script": "foo.js" }
] }
```

每个条目的 `script` 是与清单同目录的脚本文件名;`kind` 可为 `manga`、`anime` 或 `novel`,省略时兼容旧清单并按 `manga` 处理。脚本形如 `var __source = { meta, prepareDiscovery, handleDiscovery, … }`。

## 小说源与本地书籍

小说源继续使用现有的 `prepare*/handle*` 两阶段协议,网络请求由宿主执行。发现、板块、搜索、详情和目录分别使用：

- `prepareDiscovery` / `handleDiscovery`
- `prepareSection` / `handleDiscovery`
- `prepareSearch` / `handleSearch`
- `prepareMangaInfo` / `handleMangaInfo`
- `prepareChapterList` / `handleChapterList`

`handleChapter` 返回单个正文对象,不能返回漫画图片列表：

```json
{
  "format": "html",
  "content": "<p>正文</p>",
  "baseUrl": "https://example/novel/1/",
  "resources": {}
}
```

`format` 支持 `text` 或 `html`;HTML 会在显示与离线保存前清洗。每次详情和目录只属于当前选中的一个源,不会自动拼接不同来源的章节。

Windows 与 Android 均支持导入 TXT 和 EPUB。TXT 支持 BOM、UTF-8、UTF-16、GB18030/GBK 和手动 Big5 重试;EPUB 支持常规可重排 EPUB 2/3、NCX/NAV、图片、ruby 与字体回退。不支持 DRM、固定版式 EPUB、书内脚本、音视频或导出在线正文。

本地导入会复制到 App 私有目录。备份与云同步只包含书名、作者、文件指纹、收藏、阅读定位和阅读设置,**不会上传原始 TXT/EPUB、章节正文、封面二进制或下载缓存**。另一台设备需重新导入同一文件后按指纹接回进度。

## 运行

```bash
flutter pub get
flutter run -d windows      # 或 -d <android 设备>
```

- **Windows**:需安装 Visual Studio(Desktop C++ 工作负载)与 WebView2 Runtime(Win10/11 通常自带);`flutter_inappwebview` 的 Windows 支持需 NuGet CLI 在 PATH。
- **Android**:JDK 17;首次构建按 Flutter 提示配置 Android SDK / 许可。

## 构建发布

打形如 `v1.2.3`(或 `v1.2.3-beta.1`)的 tag,GitHub Actions 自动构建并发布 Windows + Android(见 [`.github/workflows/release.yml`](.github/workflows/release.yml))。

## 许可

[MIT](LICENSE) © TypeDreamMoon
