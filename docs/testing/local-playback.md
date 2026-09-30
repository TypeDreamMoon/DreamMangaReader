# 本地播放验收记录

更新时间：2026-10-01

分支：`codex/source-search-pagination`

基线：`upstream/main`
状态：自动化验证完成；Android、Windows 运行时验收待执行（含 Android 路线 A 真机 spike 与 Kotlin 编译）。

## 本次范围

- 新增「本地播放」：把本机视频/音频目录或单个文件加入本地库，直接播放，不复刻文件。
- 数据层：`LocalMediaStore`（`<support>/local-media/index.json`）、`LocalLibraryScanner`（Windows `dart:io` 递归）、`LocalEpisodeParser`（剧集号/季解析、字幕配对）、`LocalMediaBridge`（Android SAF）。
- 播放层：`buildLocalTrack`、`LocalTrackProvider`、`LocalPlayerAdapter`（不调 `configure()`、不配网络参数）。
- 界面：`LocalLibraryPage`、`LocalLibraryDetailPage`、`LocalPlayerPage`，入口在书架页顶部动作区与设置页「本地播放」分组。
- 进度复用番剧库：`sourceId = 'local'`、`animeId = 库 id`、`episodeId = 条目 id`；本地条目在历史/书架里以「番剧」形态出现（M1 接受的副作用）。
- 不包含：备份/同步、封面抽帧、时长探测、`ShelfKind.local`、Windows 拖拽与文件关联（均为 M2/M3）。

## 自动化结果

### 本地播放测试集

执行范围：`test/local_*_test.dart`。

- 测试文件：12
- 测试用例：188
- 结果：188 通过，0 失败

| 测试文件 | 用例 | 覆盖 |
| --- | --- | --- |
| `test/local_episode_parser_test.dart` | 64 | 文件名解析（季/集/多集/年份/噪声括号）、自然排序、字幕语言与配对、扩展名白名单 |
| `test/local_library_scanner_test.dart` | 21 | 递归扫描、跳过目录、超长路径计入 skipped、条数上限截断、进度回调 |
| `test/local_media_store_test.dart` | 34 | 索引读写与损坏回退、去重、扫描合并保住 id、`markPlayed`、`removeItem`/`removeLibrary` 不删源文件、导出导入、Scope 通知 |
| `test/local_track_test.dart` | 8 | `file:` URL 构造、空位置与 `content://` 拒绝、字幕透传 |
| `test/local_track_provider_test.dart` | 5 | `refresh` 恒非空、`matchRefreshed`/`lowerQuality`/`alternateLine` 语义 |
| `test/local_player_adapter_test.dart` | 11 | 流转发、`open` 用 `startAt`、**从不调用 `configure()`**、换集清空字幕、`rebuildDecoder` 恢复外挂字幕 |
| `test/local_media_bridge_test.dart` | 22 | Dart 侧通道契约 + 原生源码契约（channel 名、两类 Intent、`takePersistableUriPermission`、`buildChildDocumentsUriUsingTree`、`openFileDescriptor(uri,"r")`、`/proc/self/fd/$fd`、fd 强引用、MainActivity 注册；并断言 Manifest 不含 `READ_MEDIA_VIDEO`/`MANAGE_EXTERNAL_STORAGE`） |
| `test/local_library_actions_test.dart` | 10 | 添加文件夹/文件、重复位置提示、扫描失败仍建库且提示脱敏（不含真实路径与文件名）、重新扫描保住 id、移除库不删文件 |
| `test/local_library_page_test.dart` | 4 | 空态两种入口、库卡片、进详情页、移除库只删索引 |
| `test/local_library_detail_page_test.dart` | 3 | 剧集列表与「已看」「文件不存在」徽章、继续观看从历史续播、移除条目不动文件 |
| `test/local_player_page_test.dart` | 4 | 打开首集并从历史续播、播完自动下一集、`content://` 经桥 `openFd`/退出 `releaseFd`、进度回写番剧库 |
| `test/local_playback_spike_page_test.dart` | 2 | 非 Android 拒绝调用桥并说明用途；Android 走通 选目录 → 列子项 → openFd → 释放 |

### 静态检查

- `flutter gen-l10n`：成功（新增 39 个 `local_` 键，简中/繁中/英/日四份 arb 齐全）。
- `flutter analyze --no-pub`：`No issues found!`
- `git diff --check`：无输出。

### 尚未验证的编译环节

- **Kotlin 未编译**：`android/app/src/main/kotlin/.../local/LocalMediaBridge.kt` 与 `MainActivity.kt` 的改动**没有经过编译器校验**，目前只有 Dart 侧的源码契约测试（`test/local_media_bridge_test.dart`）。两次编译尝试都失败在**与本次改动无关的前置步骤**上：
  - `gradle :app:compileDebugKotlin --offline`（缓存 gradle 8.13）→ `No cached version of com.android.tools.build:gradle:8.12.1 / org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.0 available for offline mode`。
  - 联网重跑（同一 gradle 8.13，本机有 `ANDROID_HOME`/`JAVA_HOME`/`android/local.properties`）→ 依赖解析耗时 7m25s 后失败在 `media_kit_libs_android_video-1.3.8/android/build.gradle:83`：该插件要从 GitHub Releases 下载 libmpv 的 4 个 jar（`v1.1.7/default-*.jar`），本机到 `github.com` 连接超时（镜像可用，但当时未预置 jar）。
  - 因此**编译从未走到 `:app:compileKotlin`**，既不能证明也不能否证本次 Kotlin 改动的正确性。作者侧构建前必须先跑一次 `flutter build apk`（或 Android Studio 编译）；若同样卡在 libmpv jar 下载，把 `v1.1.7/default-*.jar` 预置到 `media_kit_libs_android_video-1.3.8/android/build/v1.1.7/` 并核对 MD5 即可跳过下载。

## 待执行的运行时验收

静态与 Widget 测试不能替代真机验收（同 `docs/testing/novel-reader-overhaul.md` 的既有结论）。以下项目发布前必须补测，并把结果回填本文档。

### 测试设备

- Android 真机：待填写型号、Android 版本、SoC 与解码能力。
- Windows：待填写系统版本、缩放比例、窗口尺寸。

### 样本

样本只能放本机，不得加入 Git：

- Android：≥2GB 单文件、HEVC 10bit、mkv 多音轨各一份；同一目录带 `.srt`/`.ass` 字幕。
- Windows：同一批样本 + 一个包含多季多集与干扰文件的目录（验证排序与字幕配对）。

### Android

1. **路线 A spike（决定 A/B）**：调试页「本地 · 探针 → ⑧ 本地播放(路线 A:fd 直读)」按 ①→⑥ 走一遍，分别试「播裸路径」与「播 file://」；三种容器（mp4/mkv/ts）都要出画面且 position 推进。若不通，M1 需切路线 B（导入到应用私有目录）。
2. 首次授权后**杀进程重启**，确认库仍可读、仍能播放（`takePersistableUriPermission` 生效）。
3. 播放中确认没有整文件复制：对比 `/data` 占用变化（路线 A 应几乎不变）。
4. 权限被撤销（系统设置里改授权）后打开库 → 应出现「需要重新授权」，点它能重走 SAF 并恢复播放。
5. 文件被删除/移动 → 条目显示「文件不存在」，点它给出提示且**不自动删条目**。
6. 大文件拖动进度条、切集、后台切回，确认不崩、不卡死。
7. 播放中屏幕保持常亮；退出播放页后恢复系统行为。

### Windows

1. 添加一个大目录（>5000 文件）与一个中文名/长路径目录，确认扫描不卡 UI、超长路径被计入「跳过」。
2. 播放 `mkv`/`mp4`/`ts` 各一个，确认首帧 < 500ms（若明显偏慢，检查是否误走了网络参数配置）。
3. 剧集顺序：多季、特别篇、无集号文件混排时顺序符合预期（已知存疑：无集号且无季的条目会排到第 1 季之前）。
4. 关闭/重开应用后库与进度仍正确；「移除库」「移除条目」都不动磁盘上的源文件。

### 两端通用

1. 从书架页与设置页两处入口都能进本地库。
2. 播放进度：播到中段退出 → 重进从该位置续播；距片尾 10 秒内退出不计续播点。
3. 设置页「清空本地播放进度」后，本地条目在统一历史里消失，其它内容的进度不受影响。
4. 简中/繁中/英/日四种语言下，本地播放相关页面无截断、无缺失文案。

## 发布前结论

自动化层面已覆盖本次 M1 的主要数据契约、播放胶水与页面交互。**Kotlin 未编译**与**路线 A 未真机验证**是两个明确的发布阻塞项：前者只需一次 Android 构建即可消除，后者决定 M1 的 Android 方案是否需要从零拷贝切到导入路线。完成上述运行时验收并把结果补入本文档后，才适合交给作者发布。
