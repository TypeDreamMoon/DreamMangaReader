# 本地播放页复用番剧播放页（M1.2）

更新时间：2026-10-07
分支：`codex/local-playback`
关系：**推翻** `2026-09-30-local-playback-design.md` §4.2「不这么做，新建 `LocalPlayerPage`」的决定。
数据模型、索引、SAF 桥都不动，只换播放页的装配方式。

## 问题（实测）

M1 自己写的 `LocalPlayerPage` 只复用了 `PlaybackSessionController` 与
`AnimePlayerControls`，手势与侧边面板是第二套实现，于是与番剧播放页分叉：

| 操作 | 番剧播放页 | M1 本地播放页 |
| --- | --- | --- |
| 双击 | 播放 / 暂停 | **快进 / 快退 15s** |
| 左侧上下滑 | 亮度 | **横拖定位**（竖滑被当成拖动） |
| 右侧上下滑 | 音量 | 同上 |
| 右上角 ⋮ | 设置抽屉(字幕/倍速/画面比例/循环/截图) | 无 |
| 长按 | 3 倍速快进 | 无 |
| 锁屏 / 键盘快捷键 / 截图存相册 | 有 | 无 |

用户报的「滑动想调音量结果是快进、双击想暂停也是快进」就是这两条差异。

## 决定

**本地播放整页复用 `AnimePlayerPage`**，`LocalPlayerPage` 缩成一层壳
（路由身份 + 生命周期），本地特有的三件事收进 `LocalPlaybackHost`。

## 怎么接

番剧播放页本来就留了本地文件的缝（M1 规格 §4.2 也记了这一点）：

```dart
AnimePlayerPage(
  meta: SourceMeta(id: 'local', name: …, script: ''),   // sourceId 沿用既有约定
  animeId: 库 id, animeTitle: 库名,
  episodes: [for (item in items) Chapter(id: item.id, name: item.displayTitle)],
  index: …, initialPosition: …,
  localFilesOnly: true,                                 // 新增:本地模式
  dependencies: AnimePlayerDependencies(
    player: LocalPlayerAdapter(NativeMediaKitBackend(player, messages: …)),
    tracks: _LocalOnlyTracks(),                          // 见下
    loadTracks: (_) async => const [],
    localTrackForEpisode: host.trackFor,                 // 新增:改成异步
    videoBuilder: (fit) => Video(…),
  ),
)
```

### 1. `localTrackForEpisode` 改成异步

Android 的 `content://` 必须先用 `LocalMediaBridge.openFd` 换成
`/proc/self/fd/N`（规格 §7.2 路线 A），那是一次平台通道往返 —— 原来的
`VideoTrack? Function(String)` 装不下。改成 `Future<VideoTrack?> Function(String)`：

- `_load()` 里 `await` 它；
- `_OfflineAwareTracks.refresh()` 跟着异步（`localTrack()` 为 null 才落到 delegate）。

离线下载那条路（`_initializeNativePlayback` 里的 `localTrackForEpisode`）同步改成
`async`，行为不变。

### 2. `localFilesOnly`

本地没有源，标题栏那三个入口（收藏 / 下载这一集 / 复制链接）全要拿 `meta.id`
去问源或下载器，点下去只会失败 —— 本地模式下整组不渲染。抽屉里只有字幕与设置
两个分段，没有需要按源区分的东西，不额外处理。

### 3. `_LocalOnlyTracks`

`AnimePlayerDependencies.tracks` 是必填的 delegate，但本地每一集都由
`localTrackForEpisode` 命中（番剧页这时不会问 delegate）。给一个**返回空**的实现：
真被问到（条目没有位置、解析失败）就让会话明确失败 —— 拿别的文件顶上比失败更糟。

### 4. fd 与播放器的生命周期（`LocalPlaybackHost`）

- 同一个条目重复解析（会话恢复时会再问一次）复用已经开好的 fd，不重复开；
- 换集时释放上一集的 fd，退出播放页时释放全部 —— 提前释放会让正在读的文件变成
  已关闭的 fd；
- 播放器（`Player` + `VideoController`）由 Host 自己起，`bufferSize` 8 MiB
  （番剧是 64 MiB），不传 `protocolWhitelist`；退出时连同 adapter 一起 dispose。
  注入了 `player`（测试）时由注入方负责它的生命周期。

### 5. 断点归属

番剧播放页只在**开播那一集**接受一个 `initialPosition`，它自己不读历史。
所以本地库详情页在 push 之前把这一集的断点算好（`_resumeFor`，与「继续观看」
同一套「距片尾 10 秒内不算」规则）；从列表点进来的那一集与「继续观看」卡片
因此走同一个入口。

> 副作用（与番剧一致）：播放中切到下一集时，那一集从 0 开始，即使以前看过一半。
> M1 那份自己写的播放页会为每一集查历史，现在这条行为对齐了番剧页。

## 删掉的东西

- `lib/features/local/local_player_page.dart` 里那套自写的手势/控件/侧栏（929 → 约 320 行）；
- `lib/features/local/local_track_provider.dart` 与其测试：它的唯一用途是喂
  会话恢复的 delegate，现在由 `_LocalOnlyTracks` 顶上（本地没有清晰度/线路可言）。

## 测试

- `test/local_player_page_test.dart`：开播位置、播完自动下一集、`content://` 经桥
  `openFd`/退出 `releaseFd`、进度回写番剧库；新增断言「落地页是 `AnimePlayerPage`
  且 `localFilesOnly`」「问源的三个入口不渲染」。
- `test/local_library_detail_page_test.dart`：点列表里的一集 → 从**那一集自己的**
  历史断点续播。
- `test/anime_player_page_test.dart`：离线轨道那条改成异步签名，行为不变。

## 已知差异（留给 M3）

- 番剧播放页的「收藏」在本地模式下不渲染，本地库因此不会出现在番剧收藏里；
- 本地播放仍然不写封面（`animeCover` 用库的 `coverThumb`，M2 才有抽帧）；
- 桌面端文件关联/拖拽导入仍未做（M3）。
