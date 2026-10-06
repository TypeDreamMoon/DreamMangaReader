# 本地播放验收记录

更新时间：2026-10-01

分支：`codex/local-playback`

基线：`upstream/main`（2026-10-06 并入 `4c3fe03`，冲突已解）
状态：自动化验证完成；Android、Windows 运行时验收待执行（含 Android 路线 A 真机 spike 与 Kotlin 编译）。

## 本次范围

- 新增「本地播放」：把本机视频/音频目录或单个文件加入本地库，直接播放，不复刻文件。
- 数据层：`LocalMediaStore`（`<support>/local-media/index.json`）、`LocalLibraryScanner`（Windows `dart:io` 递归）、`LocalEpisodeParser`（剧集号/季解析、字幕配对）、`LocalMediaBridge`（Android SAF）。
- 播放层：`buildLocalTrack`、`LocalPlayerAdapter`（不调 `configure()`、不配网络参数）；M1.2 起会话与界面直接复用番剧播放页（`LocalPlaybackHost` 负责装配）。
- 界面：`LocalLibraryPage`、`LocalLibraryDetailPage`；播放页 `LocalPlayerPage` 是 `AnimePlayerPage` 的一层壳（M1.2）。入口在书架页顶部动作区与设置页「本地播放」分组。
- 进度复用番剧库：`sourceId = 'local'`、`animeId = 库 id`、`episodeId = 条目 id`；本地条目在历史/书架里以「番剧」形态出现（M1 接受的副作用）。
- **M1.1（2026-10-07）**：添加文件时按剧名**自动并入已有同剧库**、库名改用解析出的剧名、
  库与条目都支持重命名（条目名存可选的 `customTitle`）。规则与边界见
  `docs/superpowers/specs/2026-10-07-local-library-grouping-design.md`。
- **M1.2（2026-10-07）**：本地播放**整页复用番剧播放页**（`LocalPlayerPage` 只剩壳），
  手势（双击暂停、左亮度/右音量、长按倍速）、设置抽屉、锁屏、截图全部与番剧一致；
  为此把 `AnimePlayerDependencies.localTrackForEpisode` 改成异步（Android 要开 fd）。
  见 `docs/superpowers/specs/2026-10-07-local-player-reuse-design.md`。
- 不包含：备份/同步、封面抽帧、时长探测、`ShelfKind.local`、Windows 拖拽与文件关联（均为 M2/M3）；「移动条目 / 合并两个库」也不在本次范围。

## 自动化结果

### 本地播放测试集

执行范围：`test/local_*_test.dart`。

- 测试文件：12
- 测试用例：211
- 结果：211 通过，0 失败

| 测试文件 | 用例 | 覆盖 |
| --- | --- | --- |
| `test/local_episode_parser_test.dart` | 64 | 文件名解析（季/集/多集/年份/噪声括号）、自然排序、字幕语言与配对、扩展名白名单 |
| `test/local_library_scanner_test.dart` | 21 | 递归扫描、跳过目录、超长路径计入 skipped、条数上限截断、进度回调 |
| `test/local_series_test.dart` | 15 | **M1.1**：剧名归一化键、按剧/目录分组、组名与组序、SAF 目录键与目录展示名（`/document` 不当目录） |
| `test/local_media_store_test.dart` | 38 | 索引读写与损坏回退、去重、扫描合并保住 id 与 `customTitle`、`markPlayed`、`removeItem`/`removeLibrary` 不删源文件、`renameLibrary`/`renameItem` 与空白名拒绝、导出导入、Scope 通知 |
| `test/local_track_test.dart` | 8 | `file:` URL 构造、空位置与 `content://` 拒绝、字幕透传 |
| `test/local_player_adapter_test.dart` | 11 | 流转发、`open` 用 `startAt`、**从不调用 `configure()`**、换集清空字幕、`rebuildDecoder` 恢复外挂字幕（没 open 过时是空操作） |
| `test/local_media_bridge_test.dart` | 22 | Dart 侧通道契约 + 原生源码契约（channel 名、两类 Intent、`takePersistableUriPermission`、`buildChildDocumentsUriUsingTree`、`openFileDescriptor(uri,"r")`、`/proc/self/fd/$fd`、fd 强引用、MainActivity 注册；并断言 Manifest 不含 `READ_MEDIA_VIDEO`/`MANAGE_EXTERNAL_STORAGE`） |
| `test/local_library_actions_test.dart` | 15 | 添加文件夹/文件、重复位置提示、扫描失败仍建库且提示脱敏（不含真实路径与文件名）、重新扫描保住 id、移除库不删文件；**M1.1**：同剧并卡、两部剧两张卡、散装按目录归堆、不并进目录型库、改名提示 |
| `test/local_library_page_test.dart` | 5 | 空态两种入口、库卡片、进详情页、移除库只删索引；**M1.1**：⋮ 改名（空名禁用保存）只动名字 |
| `test/local_library_detail_page_test.dart` | 5 | 剧集列表与「已看」「文件不存在」徽章、继续观看从历史续播、移除条目不动文件；**M1.1**：条目改名后行标题跟着变、解析名留着；**M1.2**：点列表里的一集 → 从**那一集自己的**历史断点续播 |
| `test/local_player_page_test.dart` | 5 | 开播断点、播完自动下一集、`content://` 经桥 `openFd`/退出 `releaseFd`、进度回写番剧库；**M1.2**：落地页是 `AnimePlayerPage` 且 `localFilesOnly`、问源的三个入口不渲染、**双击=播放/暂停且不 seek、上下滑=音量** |
| `test/local_playback_spike_page_test.dart` | 2 | 非 Android 拒绝调用桥并说明用途；Android 走通 选目录 → 列子项 → openFd → 释放 |

### 静态检查

- `flutter gen-l10n`：成功（`local_` 键 47 个，简中/繁中/英/日四份 arb 齐全）。
- `flutter analyze --no-pub`：`No issues found!`
- `flutter test --no-pub`：1483 passed（2026-10-07，含 M1.1/M1.2 全部改动）。
- 书架/历史那条链路不在 `local_*` 里：`test/unified_history_page_test.dart` 新增 2 例
  （本地历史行点开进本地库；库已被移除时提示「这个本地库已经被移除了」）。
- 同步那条护栏在 `test/sync_payload_weight_test.dart`：勾满全部类别后，载荷里
  不应出现本地库名 / 条目 id / 用户目录（番剧库与本地库整体没接同步）。
- `git diff --check`：无输出。

### 并入上游时的两处非文本改动

- 上游给 `PlaybackMessages` 加了必填 `configureFailed` / `gatewayFallbackFailed`、给
  `NativeMediaKitBackend` 加了必填 `messages`：本地播放页补齐（本地不走 HLS 网关，
  后一条不会真的出现）。
- 本地库读档**不排进** `app.dart` 那条启动 `Future.wait`：它读应用支持目录（`path_provider`），
  平台通道不应答时该 Future 会一直挂着，会把「自动上传监听 → 启动同步 → 追更检查」
  一起卡死（`test/app_startup_resilience_test.dart` 覆盖了这条）。

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
5. **M1.1 分组建库**：先加一集、再加同剧的另一集 → 仍然只有一张卡，提示「已并入《剧名》」；
   一次挑两部剧 → 两张卡，卡片名是剧名而不是文件名。
6. **M1.1 重命名**：库改名后卡片标题即时变；条目改名后列表、播放页标题、选集都跟着变；
   改名后**重新扫描**（或再加一集触发合并），名字不被冲掉；条目名留空保存 = 恢复解析出的原名。
7. 用「添加文件夹」加的目录型库不受 M1.1 影响：散装文件不会并进它，重扫语义不变。
8. **M1.2 播放器是同一个**：本地播放页与番剧播放页的控件/手势完全一致 ——
   双击暂停、左侧上下滑调亮度、右侧上下滑调音量、横拖定位、长按 3 倍速、
   右上角 ⋮ 打开设置抽屉（字幕 / 倍速 / 画面比例 / 循环 / 截图）、锁屏键可用；
   顶部**没有**收藏 / 下载这一集 / 复制链接（本地没有源）。
9. **M1.2 断点**：从列表点某一集 → 从那一集自己的历史位置续播；「继续观看」卡片同样。
   播放中切到下一集从 0 开始（与番剧一致）。
10. **书架 / 历史里的本地条目**：点历史横条、历史页里那条本地记录 → 进本地库详情页
    （**不是**「番剧源不可用」）；卡片副标题显示「本地播放」；本地库被移除后再点 →
   提示「这个本地库已经被移除了」；「检查更新」不会把本地条目算进去。
11. **同步**：连上云同步后，本地播放的进度与本地库索引都不该出现在云端载荷里
   （番剧库整体不在同步范围内；见 M1.2 设计文档同名小节）。

## 发布前结论

自动化层面已覆盖本次 M1/M1.1 的主要数据契约、分组建库规则、播放胶水与页面交互。**Kotlin 未编译**与**路线 A 未真机验证**是两个明确的发布阻塞项：前者只需一次 Android 构建即可消除，后者决定 M1 的 Android 方案是否需要从零拷贝切到导入路线。完成上述运行时验收并把结果补入本文档后，才适合交给作者发布。
