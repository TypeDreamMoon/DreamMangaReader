import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack; // 用本项目的 VideoTrack
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/local/local_models.dart';
import '../../core/platform/local_media_bridge.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../anime/anime_player_page.dart';
import '../anime/playback/media_kit_player_adapter.dart';
import '../anime/playback/playback_messages.dart';
import '../anime/playback/playback_session_controller.dart';
import '../anime/playback/player_adapter.dart';
import 'local_player_adapter.dart';
import 'local_track.dart';

/// 本地播放页的注入点(测试用)。
///
/// 真的播放要 media_kit 的原生库,widget 测试里造不出来;把「谁来放」和「画面长
/// 什么样」拆出来之后,页面逻辑(切集、进度、字幕、控制条映射)就能在没有原生库的
/// 环境里跑。
class LocalPlayerDependencies {
  const LocalPlayerDependencies({
    required this.player,
    required this.videoBuilder,
  });

  final PlayerAdapter player;
  final Widget Function(BoxFit fit) videoBuilder;
}

/// 本地文件播放页 = [AnimePlayerPage] + 本地装配。
///
/// **M1.2 起整页复用番剧播放页**(规格 §4.2 那个「另写一页」的决定被推翻):
/// M1 自己写的 929 行播放页只复用了会话与底栏,手势/控件两边各写一套,于是分叉了
/// —— 双击在番剧页是暂停、在本地页是快进;亮度/音量手势与右侧设置抽屉(选剧集/
/// 字幕/倍速/画面比例)在本地页根本没有。番剧页本来就留了本地文件的注入缝
/// (`AnimePlayerDependencies.localTrackForEpisode` + `file:` 轨道),所以这里只剩
/// 「装配」和「生命周期」:
///
/// - 交给番剧页的元数据:`meta.id = 'local'`(进度、收藏都按这个 sourceId 走)、
///   一个文件 = 一集(`Chapter.id` 就是条目 id,续播记录照旧对得上);
/// - 轨道解析与 fd 生命周期在 [LocalPlaybackHost] 里;
/// - 退出路由时 dispose 播放器与 fd。
///
/// 真实设备上 NativeMediaKitBackend 要原生库,所以播放器与画面由 [LocalPlaybackHost]
/// 自己起,不走番剧页那条 `_initializeNativePlayback`(它要源、HLS 网关与 authScope)。
class LocalPlayerPage extends StatefulWidget {
  const LocalPlayerPage({
    super.key,
    required this.library,
    required this.items,
    this.initialIndex = 0,
    this.initialPosition = Duration.zero,
    this.dependencies,
    this.bridge,
  });

  final LocalLibrary library;

  /// 已经排好序的剧集列表(库详情页给的顺序)。
  final List<LocalMediaItem> items;
  final int initialIndex;

  /// 从库详情页「继续观看」进来时带上的断点。
  final Duration initialPosition;

  final LocalPlayerDependencies? dependencies;

  /// Android 的 fd 解析通道;测试可注入。
  final LocalMediaBridge? bridge;

  @override
  State<LocalPlayerPage> createState() => _LocalPlayerPageState();
}

class _LocalPlayerPageState extends State<LocalPlayerPage> {
  late final LocalPlaybackHost _host = LocalPlaybackHost(
    library: widget.library,
    items: widget.items,
    index: widget.initialIndex,
    initialPosition: widget.initialPosition,
    dependencies: widget.dependencies,
    bridge: widget.bridge,
  );

  @override
  void dispose() {
    unawaited(_host.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _host.buildPage(context);
}

/// 把本地库的一集接到番剧播放页上。
///
/// 本地特有的只有三件事:
/// 1. **播放器实例**:`PlayerConfiguration` 与番剧页一致,但 `bufferSize` 降到
///    8 MiB(番剧是 64 MiB)—— 本地文件不需要预读那么多,也不传
///    `protocolWhitelist`(那是给 HTTP/HLS 的);
/// 2. **轨道解析**:条目 → `file:` 轨道。Android 的 `content://` 必须先用
///    [LocalMediaBridge.openFd] 换成 `/proc/self/fd/N`(规格 §7.2 路线 A),
///    所以解析是异步的;
/// 3. **fd 生命周期**:同一时刻只留当前这一集的 fd,换集/退出时释放 —— 提前释放
///    会让正在读的文件变成「已关闭的 fd」。
class LocalPlaybackHost {
  LocalPlaybackHost({
    required this.library,
    required this.items,
    required this.index,
    required this.initialPosition,
    this.dependencies,
    this.bridge,
    bool? windows,
  }) : windows = windows ?? Platform.isWindows;

  final LocalLibrary library;
  final List<LocalMediaItem> items;
  final int index;
  final Duration initialPosition;
  final LocalPlayerDependencies? dependencies;
  final LocalMediaBridge? bridge;
  final bool windows;

  Player? _player;
  VideoController? _videoController;
  NativeMediaKitBackend? _backend;
  LocalPlayerAdapter? _adapter;
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();

  LocalMediaBridge? _resolvedBridge;
  final List<int> _openFds = [];
  String? _openedItemId;
  LocalMediaItem? _openedItem;

  /// 画面上的质量标签:本地就一条,写「本地」。
  String _qualityLabel = '';

  bool _disposed = false;

  /// 组装要 push 的那一页。
  ///
  /// 必须在有 l10n 的 context 下调用:库名的兜底文案与质量标签都取自这儿。
  Widget buildPage(BuildContext context) {
    final l10n = context.l10n;
    _qualityLabel = l10n.local_qualityLocal;

    final Widget Function(BoxFit fit) videoBuilder;
    final PlayerAdapter adapter;
    final injected = dependencies;
    if (injected != null) {
      adapter = injected.player;
      videoBuilder = injected.videoBuilder;
    } else {
      final player = _player ??= Player(
        configuration: const PlayerConfiguration(
          bufferSize: 8 * 1024 * 1024,
          logLevel: MPVLogLevel.error,
        ),
      );
      final controller = _videoController ??= VideoController(player);
      final backend = _backend ??= NativeMediaKitBackend(
        player,
        messages: localPlaybackMessages(l10n),
      );
      adapter = _adapter ??= LocalPlayerAdapter(backend);
      videoBuilder = (fit) => Video(
        key: _videoKey,
        controller: controller,
        fit: fit,
        // 值本身就是 null(不要 mpv 自带控件,我们用自己的控制条);显式标注掉
        // 无类型注解的 null 造成的隐式下转。
        controls: NoVideoControls as VideoControlsBuilder?,
      );
    }

    return AnimePlayerPage(
      // 本地播放的 sourceId 固定 'local':进度、历史、清空进度的既有链路都认它。
      meta: SourceMeta(id: LocalSource.id, name: l10n.local_title, script: ''),
      animeId: library.id,
      animeTitle: library.name.trim().isEmpty
          ? l10n.local_unknownTitle
          : library.name,
      animeCover: library.coverThumb,
      episodes: [
        for (final item in items) Chapter(id: item.id, name: item.displayTitle),
      ],
      index: index,
      initialPosition: initialPosition,
      localFilesOnly: true,
      dependencies: AnimePlayerDependencies(
        player: adapter,
        tracks: const _LocalOnlyTracks(),
        loadTracks: (_) async => const <VideoTrack>[],
        localTrackForEpisode: trackFor,
        videoBuilder: videoBuilder,
      ),
    );
  }

  /// 一集 → 播放内核认得的轨道。找不到条目(库在别处被改了)就返回 null,
  /// 由番剧页走到「取不到流」的失败态。
  Future<VideoTrack?> trackFor(String episodeId) async {
    if (_disposed) return null;
    final item = _itemFor(episodeId);
    if (item == null) return null;
    final playable = await _openForPlayback(item);
    if (_disposed || playable == null) return null;
    return buildLocalTrack(
      playable,
      qualityLabel: _qualityLabel,
      windows: windows,
    );
  }

  LocalMediaItem? _itemFor(String episodeId) {
    for (final item in items) {
      if (item.id == episodeId) return item;
    }
    return null;
  }

  /// 把条目的位置变成「现在就能播的路径」,并接管 fd。
  ///
  /// SAF 只给出 `content://`,mpv 只认文件路径 —— 经桥换成 `/proc/self/fd/N`。
  /// 同一个条目重复解析(会话恢复时会再问一次)复用已经开好的 fd,不重复开。
  Future<LocalMediaItem?> _openForPlayback(LocalMediaItem item) async {
    if (!item.location.startsWith(_contentUriPrefix)) return item;
    final cached = _openedItem;
    if (cached != null && _openedItemId == item.id) return cached;

    await _releaseFds();
    final bridge = _resolvedBridge ??= this.bridge ?? LocalMediaBridge();
    final LocalMediaItem opened;
    try {
      final fd = await bridge.openFd(item.location);
      _openFds.add(fd.fd);
      opened = item.copyWith(location: fd.path);
    } on Object {
      // 打开失败:让上层看到「这一集取不到流」,别拿旧 fd 顶上。
      return null;
    }
    final subtitles = <LocalSubtitle>[];
    for (final subtitle in item.subtitles) {
      if (!subtitle.location.startsWith(_contentUriPrefix)) {
        subtitles.add(subtitle);
        continue;
      }
      try {
        final fd = await bridge.openFd(subtitle.location);
        _openFds.add(fd.fd);
        subtitles.add(LocalSubtitle(
          location: fd.path,
          label: subtitle.label,
          language: subtitle.language,
        ));
      } on Object {
        // 字幕打不开不该拦住正片,丢掉这一条即可。
      }
    }
    _openedItemId = item.id;
    _openedItem = opened.copyWith(subtitles: subtitles);
    return _openedItem;
  }

  /// 释放当前这批 fd(换集、退出播放页时调)。
  Future<void> _releaseFds() async {
    final bridge = _resolvedBridge;
    final fds = List<int>.from(_openFds);
    _openFds.clear();
    _openedItemId = null;
    _openedItem = null;
    if (bridge == null) return;
    for (final fd in fds) {
      try {
        await bridge.releaseFd(fd);
      } on Object {
        // 释放失败不该拦住换集/退出。
      }
    }
  }

  /// 退出播放页:关播放器 + 释放全部 fd。
  ///
  /// 注入了 player 时由注入方负责它的生命周期(与 widget 测试的既有规矩一致)。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _releaseFds();
    final adapter = _adapter;
    _adapter = null;
    _backend = null;
    if (dependencies == null) {
      await adapter?.dispose();
      await _player?.dispose();
    }
    _player = null;
    _videoController = null;
  }
}

/// SAF 的 document uri 前缀(位置上唯一需要特殊对待的东西)。
const String _contentUriPrefix = 'content://';

/// 本地播放的轨道提供者:两条退路都走不到 —— 每一集都由
/// [LocalPlaybackHost.trackFor] 现给轨道([AnimePlayerDependencies.localTrackForEpisode]
/// 命中时番剧页不会去问 delegate)。
///
/// 真被问到(条目没有位置、或解析失败)就返回空,让会话**明确失败**:
/// 拿别的文件顶上比失败更糟。
class _LocalOnlyTracks implements PlaybackTrackProvider {
  const _LocalOnlyTracks();

  @override
  Future<List<VideoTrack>> refresh() async => const <VideoTrack>[];

  @override
  VideoTrack? matchRefreshed(VideoTrack current, List<VideoTrack> refreshed) =>
      null;

  @override
  VideoTrack? lowerQuality(VideoTrack current, List<VideoTrack> available) =>
      null;

  @override
  VideoTrack? alternateLine(VideoTrack current, List<VideoTrack> available) =>
      null;
}

/// 本地播放的文案包。
///
/// 与番剧页同一套字段:本地虽然不走 HLS 网关(`gatewayFallbackFailed` 只是凑齐
/// 必填),但**同一个 mpv 后端**,「一集解析不出可播放地址」这类话说的是同一件事。
PlaybackMessages localPlaybackMessages(AppLocalizations l10n) => PlaybackMessages(
      // 本地场景没有「解析不出线路」这回事,这句只可能是文件不可读。
      noRoute: l10n.local_playbackFailed,
      bufferTimeout: l10n.player_bufferTimeout,
      recovering: l10n.player_recovering,
      recoverFailed: l10n.player_recoverFailed,
      configureFailed: l10n.player_configureFailed,
      gatewayFallbackFailed: l10n.player_gatewayFallbackFailed,
    );
