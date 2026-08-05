# 番剧播放器恢复与 HLS 缓存验证记录

日期：2026-08-05

分支：`codex/anime-player-resilience`

## 已验证功能

- 播放状态由统一控制器管理：连接、缓冲、恢复、失败和手动重试。
- 连续故障按顺序执行：重开当前地址、刷新同清晰度地址、降低自动清晰度、备用线路。
- 断线重开和 HLS 网关直连回退都会恢复最近播放位置。
- 手动选择清晰度后启用手动锁，不再自动降清晰度。
- HLS 主清单、TS、fMP4、`EXT-X-MAP`、Byte Range 和 AES-128 均通过回环网关测试。
- 私有 Header 会传给所有上游 HLS 请求，但不会传给本机回环请求，也不会写入缓存文件名或索引。
- VOD 分片支持并发去重、原子写入、LRU、在用保护和有限预取；Live HLS 不做完整磁盘归档。
- 视频缓存额度可选：关闭、256 MiB、512 MiB（默认）、1 GiB；可单独查看占用并立即清理。

## 自动验证

- `flutter test`：337 项全部通过。
- `flutter analyze`：无问题。
- `git diff --check`：通过。
- 协议集成测试使用本机故障 HTTP 服务，验证了私有 HLS Header、缓存命中、网关失败后的普通播放器回退、42 秒续播和 Token 不落盘。
- 播放器聚焦测试覆盖 HLS 解析、libmpv 网络参数、恢复状态机、清晰度策略、缓存存储、回环网关、media_kit 适配器、页面状态和设置面板。

## Windows Debug

- `flutter run -d windows --debug --no-pub` 构建成功。
- `dream_manga_reader.exe` 成功启动，窗口标题为 `Dream Manga Reader`。
- 日志确认 `package:media_kit_libs_windows_video registered.`，Debug 目录包含 `libmpv-2.dll`、ANGLE、Flutter 和播放器插件 DLL。
- 应用窗口通过 `CloseMainWindow()` 正常关闭，`flutter run` 随后退出。
- 首次构建时插件内置 CMake 下载生成了 0 字节的 mpv/ANGLE 压缩包；改用各插件声明的官方 URL 下载并校验其声明 MD5 后构建成功。NuGet 仅通过本次命令的临时 PATH 提供，没有修改系统 PATH。
- 关闭时 `flutter_inappwebview_windows` 输出 WebView 资源状态析构警告；未观察到播放器或应用启动崩溃。

## 尚未验证

- 当前没有 Android 设备，Android 仅完成自动测试和静态分析，不能声明真机运行通过。
- 本轮没有制作 Windows 或 Android 发布包。
- Windows 烟测确认了应用和原生播放器依赖能够启动，但没有自动从首页进入真实在线番剧，因此真实站点的首帧、手动拖动和在线清晰度切换仍需后续人工真机/桌面联调。
