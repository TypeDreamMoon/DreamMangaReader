# 本地播放（本地媒体库）设计

日期：2026-09-30
状态：已确认，等待实施计划
目标平台：Android、Windows

---

## 1. 背景

项目已经具备完整的 libmpv 播放内核，且**已经在播放本地文件**：番剧离线下载把 HLS 包写到应用私有目录，播放时用

```dart
VideoTrack(url: Uri.file(manifest, windows: Platform.isWindows).toString(), quality: …)
```

交给同一套 `PlayerAdapter` / `PlaybackSessionController`（lib/features/anime/anime_player_page.dart:461-472）。也就是说「本地视频能不能播」这个问题已经被验证过了，缺的是**用户自己挑选的、不在应用私有目录里的**媒体文件怎么进来、怎么被组织成一个库、怎么续播。

本设计新增「本地播放」能力：用户选择一个文件夹或若干文件，应用把它们组织成本地媒体库（库 → 剧集/文件），用现有的播放内核与播放控制条播放，并复用现有的进度/历史体系记录续播点。

### 1.1 与既有设计的关系

- `docs/superpowers/specs/2026-08-06-unified-download-manager-design.md`：下载内容落在应用私有目录，由 `DownloadStore` / `AnimeDownloadStore` 管理；本地播放**不接管**这些目录，但允许把它们作为「内置库」挂载（§12 M2）。
- `docs/superpowers/specs/2026-08-06-unified-library-history-design.md`：本地播放产生的进度走同一份历史投影。
- `docs/superpowers/plans/2026-08-06-anime-offline-download.md`：本地播放是它的镜像——一个「文件 → VideoTrack」，一个是「网络 → 文件」。**不共享存储实现**：`AnimeHlsPackageWriter` 只能打 HLS+AES-128 包（lib/app/anime_download_store.dart:305-565），本地已有 mp4/mkv 不需要再打包。

---

## 2. 目标

1. **Windows**：用户可以通过原生对话框选择单个视频文件、多个文件或一个文件夹；选中的内容出现在本地媒体库中并可播放，进度可续播。
2. **Android**：用户可以通过系统文件选择器（SAF）授权一个文件夹或文件；授权持久化（重启后仍可播放）；不整份复制用户的大文件。
3. **播放体验对齐番剧播放器**：播放/暂停、进度拖拽、±5s/±15s、倍速、全屏、字幕切换、上一集/下一集、剧集列表、播完自动下一集。
4. **进度与历史复用现有体系**：不需要新写一套「继续观看」。
5. 全程**不新增第三方依赖**（拖拽、媒体权限、媒体库扫描全部自写或复用已有包）。

---

## 3. 非目标与系统边界

**非目标**

- 不做在线串流、不做 URL/磁力/种子输入（番剧源已经覆盖在线场景）。
- 不做转码、转封装、烧字幕、压制（没有 ffmpeg，不引入）。
- 不绕过 DRM；AES-128 之外的加密内容一律不支持。
- 不做 SMB/WebDAV/网盘挂载。
- 不接管番剧/漫画的下载目录读写（只读挂载为库，见 §12 M2）。
- 不做音频播放器（音乐库）——视频文件里的音轨能播是自然结果，但不为纯音频做专门 UI。

**系统边界**

- 本地播放依赖平台文件访问能力，**不修改** `PlayerAdapter`、`PlaybackTrackProvider`、`PlaybackSessionController`、`TrackResolver`、`HlsCacheGateway` 的现有语义；只新增实现。
- 本地内容**不接入** `TrackResolver` 与 `HlsCacheGateway`（两者都硬性要求 HTTP(S)：lib/features/anime/playback/track_resolver.dart:131-147，lib/features/anime/playback/hls_cache_gateway.dart:46-99）。
- 本地库的索引落在应用支持目录（`getApplicationSupportDirectory()`），与 `AnimeDownloadStore` 同级、互不干扰。

---

## 4. 总体架构

### 4.1 分层

```
用户选择（Windows 对话框 / Android SAF）
        ↓
LocalLibraryScanner      枚举文件 → LocalMediaItem
        ↓
LocalMediaStore          内存态 + index.json（ChangeNotifier，屋风照 AnimeDownloadStore）
        ↓
LocalTrackProvider       LocalMediaItem → VideoTrack(file:)（PlaybackTrackProvider）
        ↓
LocalPlayerAdapter       PlayerAdapter 薄实现（包 NativeMediaKitBackend）
        ↓
PlaybackSessionController + PlaybackState + AnimePlayerControls
```

### 4.2 为什么新建播放页而不是复用 `AnimePlayerPage`

> **⚠️ 本节结论已被推翻（2026-10-07，M1.2）。** 自写的播放页与番剧页的手势/面板
> 分叉成了两套实现（双击快进 vs 暂停、没有亮度/音量手势、没有设置抽屉），实测报障。
> 现在本地播放整页复用 `AnimePlayerPage`，`LocalPlayerPage` 只剩一层壳 ——
> 见 `2026-10-07-local-player-reuse-design.md`。下面保留当时的判断与理由，作为记录。

`AnimePlayerPage` 有一个注入缝：`AnimePlayerDependencies({player, tracks, loadTracks, videoBuilder, localTrackForEpisode})`（lib/features/anime/anime_player_page.dart:142-156，注入路径从 didChangeDependencies :374-386 进入），理论上可以给它喂 `SourceMeta` + 每个文件一个 `Chapter` 就白拿全部 UI。

**决定：不这么做，新建 `LocalPlayerPage`。** 理由：

1. 该页面的输入契约是番剧语义（`SourceMeta`、番剧详情返回、质量面板、线路/清晰度锁定、`getVideo` 失败的兜底路径），本地文件没有「清晰度/线路」概念，硬塞会让本地库长期背着番剧的状态与文案。
2. 该页面把 `authScope: 'source:${meta.id}'`（:490）、`TrackResolver`（:474-486）、`HlsCacheController.instance`（:452）作为生产装配的一部分接在 `_initializeNativePlayback()` 里；本地播放要绕开这三样，注入路径下虽然可行，但一旦有人改 `_initializeNativePlayback` 就会踩到本地路径。
3. 该页面同时承担了 Android 沉浸式横屏、亮度控制、截屏、番剧下载回调等平台耦合逻辑（:393-406、:417-421、:1598-1642）。

**代价与对冲**：新建页面需要自己组装状态机与 UI。为此——播放状态机**直接复用** `PlaybackSessionController`（不重写），播放控制条**直接复用** `AnimePlayerControls`（lib/features/anime/anime_player_controls.dart:14-71，已是被动受控组件）。新建页面实际只写「装配 + 手势 + 进度落库」，预计 300 行量级。

### 4.3 复用与新增一览

| 复用（不改） | 新增 |
| --- | --- |
| `PlaybackSessionController`、`PlaybackState`、`PlaybackMessages` | `LocalMediaStore`、`LocalLibraryScanner`、`LocalEpisodeParser` |
| `NativeMediaKitBackend`（lib/features/anime/playback/media_kit_player_adapter.dart:37-149） | `LocalPlayerAdapter implements PlayerAdapter` |
| `AnimePlayerControls` | `LocalTrackProvider implements PlaybackTrackProvider` |
| `AnimeLibraryStore.saveProgress/historyFor` | `LocalLibraryPage`/`LocalLibraryDetailPage`/`LocalPlayerPage` |
| `SubtitleAsset`/`SubtitleOption`/`VideoTrack` | `LocalMediaBridge.kt` + Dart 侧封装 |
| `lib/ui/*` 组件、l10n 四份 arb | `local_` 前缀文案 |

---

## 5. 数据模型与持久化

### 5.1 类型（新增 lib/core/local/local_models.dart）

```dart
enum LocalLibraryKind { folder, file }        // folder=目录授权; file=单个/多个文件

class LocalLibrary {
  final String id;              // uuid v4（crypto 包已在依赖里）
  final String name;            // 目录名 / "单独的文件"
  final LocalLibraryKind kind;
  final String? path;           // Windows: 绝对路径（反斜杠）
  final String? treeUri;        // Android: SAF tree/document uri（含持久授权）
  final int addedAt;            // epoch ms
  final int lastScannedAt;
  final String? coverThumb;     // 库封面缩略图（M2）
}

class LocalMediaItem {
  final String id;              // uuid，进度记录的 episodeId
  final String libraryId;
  final String title;           // 清理后的文件名（去扩展名、去分辨率/CRC 噪声）
  final String location;        // Windows: 绝对路径; Android: document uri
  final int? season;            // 从文件名解析
  final int? episode;           // 从文件名解析
  final int sizeBytes;
  final int? durationMs;        // M2 探测后回填; M1 允许为空
  final List<LocalSubtitle> subtitles;   // 同目录同名 .srt/.ass/.vtt/.ssa
  final String? thumbPath;      // M2 抽帧
  final int addedAt;
}

class LocalSubtitle { final String location; final String label; final String? language; }
```

**身份、去重与可用性（对齐既有本地内容先例）**

- **身份**：`LocalMediaItem.id` 用 uuid（`crypto` 已在依赖里），仅作内部键与进度的 `episodeId`；**去重**另用 `dedupeKey`——Windows 取规范化绝对路径（`File(path).absolute.path`，比较时大小写归一），Android 取 document URI 字符串。`dedupeKey` 已存在时跳过并提示「该文件已在库中」。
- **为什么不像本地导入小说那样用 `sha256` 做身份**：小说先例是**把文件复制进应用私有目录**（`<support>/novels/local/<sha256>/`，lib/core/novel/txt_novel_importer.dart:57-82），sha256 同时充当内容指纹与目录名；本地视频**不复制文件**（§7.2 路线 A、Windows 直接引用），对 GB 级文件做全量 sha256 是不可接受的成本。M2 若需要内容指纹（判断文件被替换），改用「路径 + size + mtime」的廉价指纹。
- **`available` 由文件系统推导、绝不持久化**：对齐 `NovelLibraryEntry`（lib/app/novel_library_store.dart:279-304 构造时、:427-428 加载时计算，`_pathExists` :825；UI 据此禁用点击 lib/features/library/library_page.dart:212-216）。本地视频条目在列表渲染/播放前各做一次存在性检查（Windows `FileSystemEntity.typeSync`，Android 桥 `stat`），结果不进 JSON。

### 5.2 落盘（新增 lib/app/local_media_store.dart）

屋风照 `AnimeDownloadStore`（lib/app/anime_download_store.dart:23-247）：

- 索引：`{getApplicationSupportDirectory()}/local-media/index.json`，写 `.tmp` → rename 的原子替换，保留 `index.json.backup` 一份。
- 目录名/文件名一律过 `_safeName`（`[^A-Za-z0-9_.-] → _`，同 lib/app/download_store.dart:316）后再参与拼接；**本地库不复制媒体文件，只在索引里存绝对路径/URI**。
- `ChangeNotifier`，暴露 `libraries`、`items(libraryId)`、`item(id)`、`addLibrary(...)`、`removeLibrary(id)`、`rescan(id)`、`markPlayed(id, position, duration)`、`exportData()`/`importData()`。
- 导入导出**只导库结构（路径与标题），不导文件本身**，且不含任何凭据（本地库没有凭据）。
- 索引损坏时按「备份 → 空库 + 提示重新扫描」降级，不抛异常阻塞启动。
- **装配点**：`LocalMediaStore` 照 `NovelLibraryStore` 的三步接入 `lib/app/app.dart`——构造（app.dart:53-58）、启动加载（:87-139）、嵌套进 Scope 树（:207-227），并自带 `LocalMediaScope extends InheritedNotifier`（写法样式见 lib/app/novel_library_store.dart:804-822）。
- **目录隔离**：本地播放只用 `<support>/local-media/`（索引 + M2 缩略图），**不与** `<support>/downloads`（漫画页图，lib/app/download_store.dart:228-230）、`<support>/novels/local`（导入小说）、`<support>/anime-downloads`（番剧 HLS，lib/app/anime_download_store.dart:568-569）混用；路线 B 的导入目录用 `<support>/local-media/import/`。
- 路线 B 的导入**不走** `DownloadTask`/`DownloadExecutor`（lib/core/downloads/download_task.dart:5、lib/core/downloads/download_executor.dart:4），避免与下载管理器语义、策略（`downloads.policy.*`）和任务 JSON 的保留键约束（download_task.dart:200-208）纠缠。

### 5.3 剧集解析与排序（新增 lib/core/local/local_episode_parser.dart）

纯函数、无 Flutter 依赖、可直接单测：

- 季集：`S01E02`、`s1e2`、`1x02`、`第 12 话/集/期/部`、`EP12`/`E12`、`[12]`、尾部 `- 12`、纯数字文件名。
- 清理噪声：`1080p`、`x265`、`HEVC`、`WEB-DL`、`BDRip`、`[字幕组]`、CRC 括号、`_`/`.`/`-` 分隔线归一到空格。
- 排序：先按 `(season ?? 0, episode ?? 大数)`，再按自然排序（数字段按数值比较，`10` 排在 `9` 之后），最后按文件名。
- 字幕配对：同目录、同 basename、扩展名在 `{srt, ass, ssa, vtt, sub}` 内的文件配为外挂字幕，中文/日文/英文字幕标签从文件名后缀（`.zh`/`.chs`/`.cht`/`.jp`/`.en`/`简体`/`繁体`）推断 `language`。
- 扩展名白名单（视频）：`mp4 mkv webm avi mov m4v ts m2ts flv wmv mpg mpeg ogv`；音频：`mp3 flac aac m4a ogg opus wav`（可播但不做专门 UI）。

### 5.4 进度、续播、历史（复用，不新建）

直接复用 `AnimeLibraryStore`（lib/app/anime_library_store.dart:224-260）：

| 字段 | 取值 |
| --- | --- |
| `sourceId` | 常量 `LocalSource.id = 'local'` |
| `animeId` | `LocalLibrary.id` |
| `title` | `LocalLibrary.name` |
| `episodeId` | `LocalMediaItem.id` |
| `episodeName` | `LocalMediaItem.title` |
| `episodeIndex` | 排序后的下标 |
| `position` / `duration` | 来自 `PlaybackState` |

- 读回用 `historyFor(LocalSource.id, libraryId)`（:144-145）→ 得到上次播放的 `episodeId` 与 `positionSeconds`。
- 写回节流沿用页面的 `flushPending()` 模式（暂停、切集、dispose 时冲刷，:306-313）；不要自己再写一套 debounce。
- 续播策略对齐番剧：距片尾 10 秒内不计续播点（lib/features/anime/playback/playback_session_controller.dart:573-580 的既有行为）。
- **副作用（M1 接受）**：本地条目会以「番剧」形态出现在统一历史里（`UnifiedHistoryProjector` 吃 `AnimeHistoryEntry`，lib/features/library/unified_history.dart:71-90）。M2 再评估加 `UnifiedHistoryKind.local` / `ShelfKind.local`，届时需要动的完整清单：
  1. `enum ShelfKind`（lib/features/library/shelf_item.dart:9）+ `enum UnifiedHistoryKind`（lib/features/library/unified_history.dart:5）+ 一个 `ShelfItem.local(...)` 工厂（shelf_item.dart:15-58）。
  2. 投影：`ShelfProjector.build(...)`（shelf_item.dart:92-117，调用点 lib/features/library/library_page.dart:367）与 `ShelfProjector.updateTargets(...)`（:126-152）——本地条目没有 `(sourceId, itemId)`，必须像 `:133-142` 处理本地小说那样返回 `null` 跳过更新检查。
  3. 卡片与徽标：`shelf_card.dart:15-26`（图标/标签）、`:83-113`（封面）、`:117-130`（sourceId/itemId 占位，本地小说返回 `'local'`）。
  4. 交互：`_openItem`（library_page.dart:197-219）、长按动作（:244-320，本地删除模式参考 :310-355）、历史磁贴 switch（:614-657）。
  5. 分档 chips 会自动跟随 `ShelfKind.values` 生成（library_page.dart:533）。

### 5.5 与「本地导入小说」先例的对齐

项目里已经有「本地内容」这一类的成熟先例，本地播放应逐条对齐它的既有约定，而不是另立一套：

| 维度 | 本地导入小说（先例） | 本地视频（本设计） |
| --- | --- | --- |
| 身份 | `key = 'local:<sha256>'`，`sourceId/novelId == null`（novel_library_store.dart:279-304） | `id` = uuid + `dedupeKey`（Windows 路径 / Android URI）；同样不依赖任何 source |
| 内容位置 | 复制进 `<support>/novels/local/<sha256>/` | **不复制**，只记路径/URI（路线 A）；路线 B 复制进 `<support>/local-media/import/` |
| 可用性 | `available` 运行时由文件系统推导，UI 不可点 | 同左（§5.1） |
| 元数据语义 | `NovelLibraryEntry.isLocal => origin != NovelOrigin.remote`（:342） | `LocalLibraryKind` + `LocalSource.id == 'local'` |
| 删除 | `deleteLocalNovelDirectory`，根目录包含守卫（novel_library_view.dart:489-506，`resolveSymbolicLinks` + `FileSystemException('拒绝删除 App 小说目录之外的路径')`） | 只删索引；**永不删除用户源文件**（删除应用私有目录内的内容时同样加根包含守卫） |
| 进度 | `NovelLibraryStore.saveProgress(key, locator)` | `AnimeLibraryStore.saveProgress(sourceId: 'local', ...)` |

### 5.6 备份与同步的边界（M1：不接入）

- `buildBackupData`（lib/app/backup.dart:18-31）与 `SyncData.build`（lib/core/sync/sync_data.dart:191-265）会把库元数据带出去；本地路径相关的键靠 `_isDeviceSecretKey`（backup.dart:58-77，含 `'privatepath'`/`'localpath'`）剥离，`NovelLibraryStore.exportData({includeLocalPaths = false})`（:366-380）在同步时默认不导路径。
- **M1 决定：`LocalMediaStore` 不进入自动备份与同步**。理由：本地视频的条目脱离了路径就没有意义（不像小说有内容指纹可迁移），跨设备同步只会产生一堆 `available: false` 的残留行；而既有删除对账只处理 `origin == 'remote'`（sync_data.dart:680、:717），本地行不会被正确清理。
- M2 提供**手动导出库清单**（标题 + 相对结构 + 可选绝对路径，显式勾选）作为迁移手段，不复用 sync 通道。

---

## 6. 播放内核的接入

### 6.1 本地 track 的构造规则（硬性）

```dart
VideoTrack buildLocalTrack(LocalMediaItem item, List<LocalSubtitle> subs) => VideoTrack(
      url: Uri.file(item.location, windows: Platform.isWindows).toString(), // 'file:///F:/a/b.mkv'
      quality: l10n.local_quality_local,   // 质量面板里显示「本地」
      headers: null,
      hls: false,                          // 绝不能为 true
      audioUrl: null,
      subtitles: [for (final s in subs) SubtitleAsset(url: Uri.file(s.location, windows: Platform.isWindows).toString(), label: s.label, language: s.language)],
    );
```

- `hls: true` 会让 `MediaKitPlayerAdapter` 走 `HlsCacheGateway`；`HlsCacheGateway.open` 对非 HLS 直接 `ArgumentError('不是 HLS')`（lib/features/anime/playback/hls_cache_gateway.dart:279），`TrackResolver._safeHttpUri` 也会 `FormatException('HLS 地址必须是无凭据的 HTTP(S) URL')`（lib/features/anime/playback/track_resolver.dart:131-137）。
- 裸路径（`F:\a\b.mkv`）**不是合法 URL**：必须 `Uri.file(...).toString()`。既有代码用 `track.url.startsWith('file:')` 判定本地（lib/features/anime/anime_player_page.dart:190），裸路径会被误判成远端。
- 本地 track 的 `headers` 恒为 `null`，不经过 `MpvNetworkOptions`。

### 6.2 `LocalPlayerAdapter`（新增，约 60 行）

`NativeMediaKitBackend`（lib/features/anime/playback/media_kit_player_adapter.dart:37-149）已经把 media_kit 的 `Player` 包成了 `MediaKitBackend` 接口，且**没有任何 HLS/网络耦合**——`MediaKitPlayerAdapter`（:152-163）才是那个需要 `HlsSessionGateway` + `authScope` 的在线层。所以：

```dart
class LocalPlayerAdapter implements PlayerAdapter {
  LocalPlayerAdapter(this._backend, {required this.track});
  final MediaKitBackend _backend;
  VideoTrack track;

  // 直接转发 backend 的 8 条流；subtitles 用 backend.subtitleTracks
  @override Future<void> open(VideoTrack t, {Duration startAt = Duration.zero}) async {
    track = t;
    // 关键：本地文件不调用 backend.configure()，见下
    await _backend.open(t, startAt: startAt);
  }
  @override Future<void> rebuildDecoder(Duration resumePosition) =>
      _backend.open(track, startAt: resumePosition);
  // seek / play / pause / setRate / setVolume / setSubtitle / dispose 全部透传
}
```

三条必须遵守的既有约束：

1. **不要调用 `NativeMediaKitBackend.configure()`**。它给 mpv 设 `network-timeout`/`user-agent`/`http-proxy`/`stream-lavf-o`/`demuxer-lavf-o`，失败时抛 `StateError('无法配置播放器网络参数 $key: $error')`（media_kit_player_adapter.dart:74-103）。本地文件不需要这些；预读参数（`demuxer-readahead-secs=20`、`demuxer-max-bytes=64MB`，:96-102）对大文件反而是内存负担，M1 直接用 mpv 默认值。
2. **断点必须走 `open(startAt:)`**，不能 open 之后再 seek。既有注释已写明原因：media_kit 把 `Media.start` 写进 mpv 的 on_load 钩子，而 post-open seek 在文件尚未打开时会被丢弃（media_kit_player_adapter.dart:105-117，playback_session_controller.dart:216-239）。
3. `Player` 的构造：本地播放**不传** `protocolWhitelist`（那是 `MpvNetworkOptions.protocolWhitelist`，含 `crypto`/`http`，见 lib/features/anime/playback/mpv_network_options.dart:13-24），`bufferSize` 可降到 8–16 MiB（番剧页是 64 MiB，:442-448）。

### 6.3 `LocalTrackProvider`（新增）

```dart
class LocalTrackProvider implements PlaybackTrackProvider {
  @override Future<List<VideoTrack>> refresh() async => [currentTrack]; // 重扫后同一条
  @override VideoTrack? matchRefreshed(VideoTrack c, List<VideoTrack> r) => r.isEmpty ? null : r.first;
  @override VideoTrack? lowerQuality(VideoTrack c, List<VideoTrack> a) => null;   // 本地无清晰度
  @override VideoTrack? alternateLine(VideoTrack c, List<VideoTrack> a) => null;  // 本地无线路
}
```

理由：`PlaybackSessionController._recover`（playback_session_controller.dart:482-569）的恢复阶梯是 `rebuildDecoder` → `refresh()/matchRefreshed` → `lowerQuality`/`alternateLine`。如果 `refresh()` 也返回 null 或空，单个不可变文件会在 1s/2s/4s 三次退避后直接进入 `PlaybackPhase.failed`。让 `refresh()` 返回当前文件（可能已重扫、重算字幕），可以把第 0、1 轮变成「重开同一文件」，只有真正打不开（文件被删/权限被撤）才落到 failed。

### 6.4 不接入的东西

- `TrackResolver`、`HlsCacheGateway`、`HlsCacheController.instance`：HTTP-only，本地不需要。
- `MediaKitPlayerAdapter`：需要 `HlsSessionGateway` + `authScope`。
- `QualityPolicy`/`QualityLevel`（lib/features/anime/playback/quality_policy.dart）：生产路径里已无人引用（仅测试引用），本地更不需要。
- `MpvNetworkOptions`、`AppProxy`。

### 6.5 字幕

- 外挂字幕通过 `VideoTrack.subtitles` → `SubtitleOption.asset(...)` 进入 `PlaybackSessionController` 的轨道表，`setSubtitle` 最终执行 `SubtitleTrack.uri(url)`（media_kit_player_adapter.dart:136-146）；本地 `.srt` 绝对路径直接可用，与番剧源声明字幕走同一条路。
- `open()` 会清空当前字幕选择（media_kit_player_adapter.dart:208-210），只有外挂字幕会被恢复（:244-252）；**切换剧集后要重新应用用户选中的字幕偏好**。
- 编码：字幕文件可能是 GBK/GB18030，项目已有 `charset` + `charset_converter`（小说模块在用）。M1 允许交给 mpv 自己猜编码；M2 若出现乱码，按小说模块的套路先转 UTF-8 再交给 mpv。
- 内嵌字幕由 mpv 轨道表给出，`NativeMediaKitBackend.subtitleTracks` 已过滤 `no`/`auto` 伪轨道（media_kit_player_adapter.dart:59-71）。

### 6.6 单调、无网络的状态机

- 不实现「清晰度锁定」「线路切换」按钮：`AnimePlayerControls.onQuality` 传 `null` 时按钮不出现（组件内已是可选入参，lib/features/anime/anime_player_controls.dart:65-71）。
- `PlaybackState.copyWith` 在未传 `message` 时会**清空**消息（playback_state.dart:61），本地页刷新状态时要显式带上 `state.message`。
- `PlaybackMessages` 需要 4 条文案（lib/features/anime/playback/playback_messages.dart:6-25）：`noRoute`（本地场景改成「文件不存在或不可读」）、`bufferTimeout`、`recovering`、`recoverFailed`。

---

## 7. 平台方案

### 7.1 Windows

| 能力 | 方案 | 里程碑 |
| --- | --- | --- |
| 选文件/多选 | `file_picker` 的 `pickFiles(type: FileType.custom, allowedExtensions: [...])`，桌面原生对话框，**不复制文件**（复制行为只存在于 Android 实现） | M1 |
| 选文件夹 | `file_picker` 的 `getDirectoryPath()` | M1 |
| 播放 | 绝对路径 → `Uri.file(path, windows: true)` | M1 |
| 扫描 | `dart:io` `Directory.list(recursive: true)`，跳过隐藏目录、符号链接环、`$RECYCLE.BIN`/`System Volume Information` | M1 |
| 外部变更 | 每次进入库页面重扫（增量：按 size+mtime 判断是否变化，不引入 `Directory.watch`） | M1 |
| 拖拽文件到窗口 | 需要 C++ 侧 `DragAcceptFiles` + `WM_DROPFILES` 处理（windows/runner/，现有 `kWindowChannelName = "dream_manga_reader/window"`，flutter_window.cpp:15） | M3 |
| 文件关联 /「打开方式」 | windows/installer/DreamMangaReader.iss 注册 ProgID | M3 |
| 命令行打开 | windows/runner/main.cpp:22-25 已把 argv 传到 Dart（`set_dart_entrypoint_arguments`），但 lib/main.dart:18 的 `main()` 不接收参数，需要改成 `main(List<String> args)` 并解析 | M3 |
| 系统媒体键 / 托盘播放控制 | 复用现有托盘 Win32 代码（flutter_window.cpp 内已有 `NOTIFYICON_VERSION_4`/`ShowFromTray`） | M3 |

### 7.2 Android

**选文件必须自写桥，不能用 `file_picker` 的 video 类型**：`FilePickerDelegate/FileUtils.kt:533-575` 的 `openFileStream` 会把选中文件整份复制到 `context.cacheDir/file_picker/<System.currentTimeMillis()>/<name>`（:538-540）。挑一个 4GB 电影会先复制 4GB，不可接受。

新增 `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/local/LocalMediaBridge.kt`（channel `dream_manga_reader/local_media`，屋风照已有的 `gallery/GalleryBridge.kt` / `downloads/ContentDownloadBridge.kt`），Dart 侧 `lib/core/platform/local_media_bridge.dart`。方法与职责：

| 方法 | 实现 | 返回 |
| --- | --- | --- |
| `pickDirectory()` | `ACTION_OPEN_DOCUMENT_TREE` + `takePersistableUriPermission(READ)` | tree uri + 显示名 |
| `pickFiles()` | `ACTION_OPEN_DOCUMENT`（`video/*`，`allowMultiple = true`）+ 逐个持久授权 | document uri 列表 + 显示名 + size |
| `listChildren(treeUri)` | `DocumentFile.fromTreeUri(...).listFiles()` 递归 | `[{uri, name, size, mime, lastModified}]` |
| `stat(uri)` | `ContentResolver.query(OpenableColumns)` | name/size/mtime |
| `openFd(uri)` | `ContentResolver.openFileDescriptor(uri, "r")`，**fd 交给播放器后由桥持有并不关闭** | `{fd, procPath: "/proc/self/fd/$fd"}` |
| `releaseFd(fd)` | 关闭并把 fd 记回可用池 | void |
| `deleteTree(uri)` | `DocumentsContract.deleteDocument`（用户在应用内移除库时可选：仅解除索引，不删文件） | void |

**播放路径（M1 内必须定案，见 §14 待验证 1）**：优先级

- 路线 A（首选）：`openFd` → 把 `/proc/self/fd/N` 作为 mpv 的输入路径。mpv 在 Android 上是普通 Linux 进程，`/proc/self/fd/N` 是可读的常规文件描述符路径（App 自身 fd 表内），理论上 `file:` 语义可用。**必须先做真机 spike 验证**，验证页放 `lib/features/spike/local_playback_spike_page.dart`（仓库已有 `lib/features/spike/` 目录）。
- 路线 B（回退）：`ContentResolver` 流式**导入**到应用私有目录（`<appSupport>/local-import/<uuid>/<name>`），带进度与空间检查，复用 downloads 的落盘硬化与（可选）前台服务屋风。代价是占用户额外空间，只在路线 A 不通时启用。
- 无论 A/B，`LocalMediaBridge` 都把「怎么打开」收敛成「给 Dart 一个可播 URL」，播放层不认识 content://。

**权限**：使用 SAF + 持久 URI 授权，**不申请** `READ_MEDIA_VIDEO`/`MANAGE_EXTERNAL_STORAGE`（当前 manifest 里没有这些权限，也不新增；AndroidManifest.xml:14-16 只有 maxSdkVersion=28 的 WRITE_EXTERNAL_STORAGE）。

**前后台**：M1 只要求应用在前台时播放正常。后台/画中画播放（前台服务 + MediaSession）列为 M3——仓库已有两个前台服务的注册先例（AndroidManifest.xml:44-53），但播放场景需要的是 mediasession 类型服务，不与下载服务混用。

### 7.3 平台对照

| 维度 | Windows | Android |
| --- | --- | --- |
| 选择入口 | `file_picker` 原生对话框 | 自写 SAF 桥 |
| 文件标识 | 绝对路径 | document/tree URI（持久授权） |
| 播放输入 | `file:///` 绝对路径 | 路线 A：`/proc/self/fd/N`；路线 B：导入后的 `file:///` |
| 扫描 | `dart:io` 递归 | 桥内 `DocumentFile` 递归 |
| 授权持久性 | 无（文件系统即权限） | `takePersistableUriPermission`，重启后有效 |
| 大文件 | 无额外拷贝 | 路线 A 无拷贝；路线 B 会拷贝 |
| 屏常亮 | `WakelockPlus`（自行调用） | 同左（番剧播放器当前**没有**做，本地播放器要自己加） |

> 屏常亮提示：`WakelockPlus` 目前只在阅读器里用（lib/features/reader/reader_page.dart:12/:173-175、lib/features/novel/novel_reader_page.dart:151），番剧播放器没有用；开关可直接复用 `library_store` 的 `keepScreenOn`（lib/core/... library_store.dart:216/:356/:999-1001 对应设置项）。

---

## 8. UI 与入口

### 8.1 入口（不新增 tab）

`HomeShell` 保持 4 个 tab（书架/发现/下载/设置，lib/features/shell/home_shell.dart:70-83）。本地库入口三处：

1. 书架页顶部动作区新增一个「本地」按钮（图标入口 → `LocalLibraryPage`）。
2. 设置页新增「本地播放」分组：库列表、默认扫描行为、清空本地进度。
3. Windows 的 M3 入口（拖拽/文件关联/命令行）落到同一条路由。

### 8.2 本地库页（新增 lib/features/local/local_library_page.dart）

- 空态：一张大卡片，两个按钮「添加文件夹」「添加文件」；Windows 额外显示「把文件拖到这里」（M3 才真正支持拖拽，M3 前隐藏）。
- 有内容：库卡片列表（名称、条目数、最近播放、封面缩略图 M2）+ 「重新扫描」「移除库」（移除只删索引，不删用户文件，需要二次确认）。
- 库详情：剧集列表（序号、标题、时长 M2、已看进度条、已看对勾），点条目直接播放；点「继续观看」从 `historyFor` 恢复。

### 8.3 播放页（新增 lib/features/local/local_player_page.dart）

- 视频面：`Video(controller: VideoController(player))`，与番剧页同一套。
- 控制层：`AnimePlayerControls`，映射关系：

| 控制条入参 | 本地页取值 |
| --- | --- |
| `position`/`duration`/`buffered`/`playing`/`buffering` | 来自 `PlaybackState` |
| `onPlayPause` | `session.setUserPaused(...)` |
| `onScrubStart` / `onSeek(target, resumeAfterSeek)` | `session.seekTo(target, resumeAfterSeek: ...)` |
| `onEpisodes` | 底部剧集面板（当前库的条目列表） |
| `onPrevEpisode`/`onNextEpisode` | 排序后相邻条目；到头传 `null` |
| `onRate` / `rateLabel` | 倍速菜单（与番剧一致：0.5–3.0） |
| `onQuality` / `qualityLabel` | `null`（不显示质量按钮），`qualityLabel` 传 `local_quality_local` |
| `onFullscreen` / `fullscreen` | 本地全屏切换 |
| `onOpenPanel` | 面板（剧集 + 字幕 + 倍速） |

- 手势：M1 做「单击显隐控制条、双击 ±15s、横向拖拽定位、纵向拖拽调音量/亮度」中的前两项 + 控制条本身；其余对齐番剧页放 M2。
- 播完自动下一集：监听 `PlaybackState.completed` → 下一项（沿用番剧页的 loopMode/autoPlay 语义，键 `'anime.player.loopMode'`/`'anime.player.autoPlay'`，lib/features/anime/anime_player_page.dart:256-257）。
- 进度：`PlaybackState.position` 变化 → 节流写 `AnimeLibraryStore.saveProgress`（§5.4）；暂停/切集/dispose 时 `flushPending()`。
- `keepScreenOn`：播放中按设置调用 `WakelockPlus.enable()`，退出时 `disable()`。

### 8.4 错误态

| 情况 | 表现 |
| --- | --- |
| 文件已被移动/删除 | 条目标灰 + 「文件不存在」，可「移除条目」或「重新定位」（M2） |
| Android 权限被撤销 | 库卡片提示「需要重新授权」，点击重新走 SAF |
| 编码不支持（mpv 报错） | 用 `PlaybackMessages.recoverFailed` 显示，允许换下一个文件；不自动删条目 |
| 扫描到 0 个可播文件 | 空态文案区分「目录为空」与「没有支持的格式」 |

### 8.5 l10n

新增 `local_` 前缀，四份 arb 齐补（`app_zh.arb` 是模板）：入口、库页、空态、剧集、播放页、错误、设置项，预计 25–35 个键。执行 `flutter gen-l10n`。

---

## 9. 异常与兼容

- **索引与文件不一致**：`LocalMediaItem.location` 指向的文件在播放前不存在 → 不进入播放页，直接提示（避免进入后 mpv 报错）。
- **扫描中断**：Android 上 `DocumentFile` 递归遇 `SecurityException` 时保留已扫到的条目并提示；不整体失败。
- **重复挂载**：同一路径/treeUri 重复添加 → 按 `path`/`treeUri` 去重，提示「该位置已在库中」。
- **路径含中文/emoji/空格**：始终 `Uri.file(...)` 构造，不做手工字符串拼接；写入索引前不做 URL 编码转换。
- **Windows 长路径**：`\\?\` 前缀不做特殊处理，超过 260 字符的路径在扫描时跳过并计数提示。
- **备份/同步**：本地库索引进入现有导出/导入路径时，只带路径与标题；不同步任何播放凭据（本地库无凭据）。
- **向后兼容**：新增字段一律可选，索引 JSON 带 `version`，读旧版本时缺失字段取默认值。

---

## 10. 安全与合规

- 不实现 DRM 绕过；AES-128 加密的 HLS 由 mpv 的 `crypto` 协议处理（既有行为，本地播放不扩大范围）。
- 写入路径（`local-media/`、路线 B 的 `local-import/`）一律做路径穿越硬化（`_safeName`），与 `DownloadStore`/`AnimeDownloadStore` 同一套规则。
- 日志与错误消息中的本地路径按现有习惯处理：`redactUrlCredentials`（playback_session_controller.dart:563）保留；用户目录名可能含真实姓名，日志里不打印完整路径，只打印文件名 + hash 前缀。
- 不申请 `MANAGE_EXTERNAL_STORAGE`、不申请媒体库读取权限；Android 只依赖 SAF 用户显式授权。
- 「移除库」默认只删索引，删源文件必须另做二次确认的显式动作（M1 不提供删源文件）。

---

## 11. 性能与资源

- 扫描：`dart:io`/`DocumentFile` 递归在 M1 可以同步走，但必须**分批**（每 200 条让出一次事件循环）以免卡 UI；> 20000 个文件时提示用户换更小的目录。
- 大文件：路线 A 零拷贝；路线 B 提供进度与剩余空间检查（`< 文件大小 × 1.1` 时拒绝并提示）。
- 内存：本地播放不设 `bufferSize: 64MiB`（番剧是网络流才需要），用 media_kit 默认值。
- 缩略图（M2）：每个库最多 N 张（默认 12），尺寸 ≤ 320px，落 `<appSupport>/local-media/thumbs/<itemId>.jpg`；抽帧失败静默跳过。
- 首帧时间：本地文件应即时（< 500ms），若首次进入出现明显等待，检查是否误走了网络参数配置（§6.2 第 1 条）。

---

## 12. 里程碑与实施顺序

**M1（Android + Windows 同时可用）**

1. 纯 Dart 层：`LocalEpisodeParser` → `LocalMediaStore` → `LocalLibraryScanner`（Windows 走 `dart:io`；Android 走桥接口，桥未就绪时实现内存假实现便于测试）。
2. `LocalPlayerAdapter` + `LocalTrackProvider` + `buildLocalTrack`（纯逻辑，可单测）。
3. Android `LocalMediaBridge.kt` + Dart 封装 + **路线 A 真机 spike**（`lib/features/spike/local_playback_spike_page.dart`）；不通则切路线 B。
4. `LocalLibraryPage` / `LocalLibraryDetailPage` / `LocalPlayerPage`。
5. 入口（书架按钮 + 设置分组）+ `app.dart` 装配 `LocalMediaStore`（app.dart:53-58/:87-139/:207-227）+ 进度落库 + `local_` 文案与 `flutter gen-l10n`。
6. 两端真机验收（§13）。

**M2（打磨）**

- 封面抽帧、时长探测、剧集自动连播的边界（跨季/特别篇）、字幕编码修正、`ShelfKind.local` + `UnifiedHistoryKind.local`（改动清单见 §5.4）、手动导出库清单（§5.6）、下载目录挂载为内置库、重新定位失效条目、手势对齐番剧页。

**M3（桌面与后台）**

- Windows 拖拽/文件关联/命令行、系统媒体键与托盘控制、Android 后台/画中画播放（MediaSession 前台服务）。

---

## 13. 验收与测试

**自动化（静态可验）**

| 测试文件（新增） | 覆盖 |
| --- | --- |
| `test/local_episode_parser_test.dart` | 季集解析、噪声清理、自然排序、字幕配对与语言推断 |
| `test/local_media_store_test.dart` | index 原子写/读回/损坏降级、去重、`_safeName` 硬化、导入导出 |
| `test/local_library_scanner_test.dart` | 用临时目录构造嵌套结构，验证过滤、扩展名白名单、跳过隐藏/回收站 |
| `test/local_track_test.dart` | `buildLocalTrack` 产出 `file:` URL、`hls == false`、Windows 反斜杠路径、字幕附件 |
| `test/local_track_provider_test.dart` | `refresh()` 非空、`lowerQuality`/`alternateLine` 返回 null、`matchRefreshed` 取首条 |
| `test/local_player_adapter_test.dart` | 用假 `MediaKitBackend` 验证**不调用 `configure()`**、`open(startAt:)` 透传、`rebuildDecoder` 用当前 track |

命令：`flutter test --no-pub test/local_*.dart`、`flutter analyze --no-pub`、`git diff --check`、`flutter gen-l10n`。`playback/` 相关新代码保持**无 `BuildContext` 依赖**，可用 `fake_async` 测试（沿用 playback_messages.dart:1-5 的既有约定）。

**真机验收（Windows 与 Android 各跑一遍）**

1. 选文件夹 → 扫描出条目 → 播放第一个 → 拖进度 → 退出 → 重新进入 → 从上次位置续播。
2. 播完自动下一集；上一集/下一集按钮边界正确。
3. 同目录 `.srt` 出现在字幕列表并能切换；切集后字幕偏好仍生效。
4. 倍速 0.5×/1.5×/2× 生效；全屏切换正常；`keepScreenOn` 生效。
5. 文件在应用外被删除后进入库 → 条目标灰并提示，不崩溃。
6. Android：≥2GB 文件、HEVC 10bit、mkv 多音轨各一个样本；授权后杀进程重启仍能播放。
7. Android：路线 A 生效时确认无整文件复制（对比 `/data` 占用变化）。
8. 关闭/重开应用后库与进度仍正确（索引读写正确）。

> 静态测试不能替代真机验收（参考 docs/testing/novel-reader-overhaul.md 的既有结论）。

---

## 14. 延后验证（实施中必须落地的未知项）

1. **Android 能否直接把 `/proc/self/fd/N` 交给 libmpv 播放**——决定路线 A/B。验证方式：spike 页 + 真机 3 种容器（mp4/mkv/ts）。
2. **mpv 在无 `VideoController`（vo=null）时 `Player.screenshot()` 是否可用**（M2 抽帧依赖）：`Player.screenshot({String? format, bool includeLibassSubtitles = false})`（pub cache media_kit-1.2.6/lib/src/player/player.dart:321，底层 `screenshot-raw`，real.dart:2742-2744）。硬解路径可能出黑帧，需评估 `screenshot-sw`。
3. **Android 大文件/10bit 的解码能力上限**（libmpv 无系统硬解兜底），需要样本实测，必要时在 UI 上给出「设备解码能力不足」的明确提示。
4. **字幕编码**：GBK 字幕是否普遍乱码；需要时按小说模块的 `charset_converter` 套路预转 UTF-8。
5. **`AnimeDownloadStore` 的 root 布局（`<appSupport>/anime-downloads`，lib/app/anime_download_store.dart:567-570）能否直接挂成内置库**（M2）：需要确认已有下载内容都能以 `file:` 直读（含 AES-128 的 `key-N.bin` 依赖 mpv `crypto` 协议，本地播放器不传 `protocolWhitelist` 时是否仍能解密）。
6. **多窗口/单实例**：命令行打开文件（M3）在已有实例运行时的行为（当前 `main.cpp` 是单窗口，未做单实例转发）。

---

## 15. 风险登记

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| 1 | 路线 A（fd 直读）真机不通 | M1 Android 需改走导入路线，体验降级（拷贝 + 占空间） | M1 第 3 步先 spike，早失败早切换；桥的接口设计对两条路线一致 |
| 2 | 复用 `PlaybackSessionController` 时恢复阶梯对单文件不友好 | 播放偶发失败时直接进 failed | `LocalTrackProvider.refresh()` 返回当前 track（§6.3） |
| 3 | 本地条目在历史/书架里显示为「番剧」 | 语义轻微混淆 | M1 接受；M2 加 `ShelfKind.local`/`UnifiedHistoryKind.local` |
| 4 | 误用 `protocolWhitelist`/`configure()` | 本地播放被网络参数拖慢或直接抛 `StateError` | §6.2 的三条硬约束 + 单测断言不调用 `configure()` |
| 5 | 大目录扫描卡 UI | 首屏卡顿 | 分批让出事件循环，> 20000 条提示 |
| 6 | 用户删源文件 | 条目失效 | 播放前存在性检查；M2 提供重新定位 |
| 7 | 与下载目录耦合后互相干扰 | 下载内容被误删/误改 | 本地播放对下载目录只读；M2 挂载为只读内置库 |

---

## 16. 实施顺序与依赖

```
Task 1  local_episode_parser（纯函数 + 单测）            ── 无依赖
Task 2  local_models + LocalMediaStore（+ 单测，含 app.dart 装配） ── 无依赖
Task 3  LocalLibraryScanner（Windows dart:io + 单测）     ── 依赖 1、2
Task 4  buildLocalTrack + LocalTrackProvider + LocalPlayerAdapter（+ 单测） ── 依赖 2
Task 5  Android LocalMediaBridge + 路线 A spike          ── 独立，可与 1-4 并行
Task 6  LocalLibraryPage / LocalLibraryDetailPage         ── 依赖 2、3、5
Task 7  LocalPlayerPage                                   ── 依赖 4、6
Task 8  入口（书架/设置）+ l10n + gen-l10n                ── 依赖 6、7
Task 9  两端真机验收记录（docs/testing/local-playback.md）── 依赖全部
```
