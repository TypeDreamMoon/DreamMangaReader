import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack; // 用本项目的 VideoTrack
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../app/anime_download_store.dart';
import '../../app/anime_library_store.dart';
import '../../app/theme/app_colors.dart';
import 'anime_player_controls.dart';
import 'playback/hls_cache_settings.dart';
import 'playback/media_kit_player_adapter.dart';
import 'playback/mpv_network_options.dart';
import 'playback/playback_session_controller.dart';
import 'playback/playback_state.dart';
import 'playback/player_adapter.dart';
import 'playback/track_resolver.dart';

/// 播放诊断开关。开着时播放全程往控制台打 `[AV]` 日志(开播/取流/卡顿/位置/mpv 报错)。
/// 平时关闭(避免刷屏);排查番剧播放问题时置 true 复现即可。
const bool kAvDiag = false;

class AnimePlaybackSurface extends StatelessWidget {
  const AnimePlaybackSurface({
    super.key,
    required this.state,
    required this.video,
    required this.onRetry,
  });

  final PlaybackState state;
  final Widget video;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.phase == PlaybackPhase.failed) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.white70, size: 42),
              const SizedBox(height: 12),
              const Text('播放失败',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  state.message ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final status = switch (state.phase) {
      PlaybackPhase.resolving => '正在获取播放地址',
      PlaybackPhase.opening => '正在连接视频',
      PlaybackPhase.buffering => '正在缓冲',
      PlaybackPhase.recovering => state.message ?? '正在恢复播放',
      _ => null,
    };
    return Stack(
      fit: StackFit.expand,
      children: [
        video,
        if (status != null)
          IgnorePointer(
            child: ColoredBox(
              color: Colors.black38,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(status,
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class AnimePlayerDependencies {
  const AnimePlayerDependencies({
    required this.player,
    required this.tracks,
    required this.loadTracks,
    required this.videoBuilder,
    this.localTrackForEpisode,
  });

  final PlayerAdapter player;
  final PlaybackTrackProvider tracks;
  final Future<List<VideoTrack>> Function(String episodeId) loadTracks;
  final Widget Function(BoxFit fit) videoBuilder;
  final VideoTrack? Function(String episodeId)? localTrackForEpisode;
}

class _OfflineAwareTracks implements PlaybackTrackProvider {
  const _OfflineAwareTracks({
    required this.delegate,
    required this.localTrack,
  });

  final PlaybackTrackProvider delegate;
  final VideoTrack? Function() localTrack;

  @override
  Future<List<VideoTrack>> refresh() async {
    final local = localTrack();
    return local == null ? delegate.refresh() : [local];
  }

  @override
  VideoTrack? matchRefreshed(
    VideoTrack current,
    List<VideoTrack> refreshed,
  ) {
    if (_isLocal(current)) return refreshed.firstOrNull;
    return delegate.matchRefreshed(current, refreshed);
  }

  @override
  VideoTrack? lowerQuality(VideoTrack current, List<VideoTrack> available) =>
      _isLocal(current) ? null : delegate.lowerQuality(current, available);

  @override
  VideoTrack? alternateLine(VideoTrack current, List<VideoTrack> available) =>
      _isLocal(current) ? null : delegate.alternateLine(current, available);

  bool _isLocal(VideoTrack track) => track.url.startsWith('file:');
}

/// 番剧播放页:media_kit(libmpv)播放一集。取源的 [MangaSource.getVideo] 拿清晰度/线路,
/// 带上防盗链 headers 交给播放器;支持上一集/下一集、切线路。
class AnimePlayerPage extends StatefulWidget {
  const AnimePlayerPage({
    super.key,
    required this.meta,
    required this.animeId,
    required this.animeTitle,
    required this.episodes,
    required this.index,
    this.initialPosition = Duration.zero,
    this.dependencies,
  });

  final SourceMeta meta;
  final String animeId;
  final String animeTitle;
  final List<Chapter> episodes; // 番剧沿用章节契约:一集=一个 Chapter
  final int index;
  final Duration initialPosition;
  final AnimePlayerDependencies? dependencies;

  @override
  State<AnimePlayerPage> createState() => _AnimePlayerPageState();
}

class _AnimePlayerPageState extends State<AnimePlayerPage> {
  late int _i = widget.index;
  List<VideoTrack> _tracks = const [];
  VideoTrack? _current;
  PlaybackState _playback = const PlaybackState(
    phase: PlaybackPhase.resolving,
  );
  Player? _nativePlayer;
  MangaSource? _source;
  PlayerAdapter? _adapter;
  Future<List<VideoTrack>> Function(String episodeId)? _loadTracks;
  VideoTrack? Function(String episodeId)? _localTrackForEpisode;
  Widget Function(BoxFit fit)? _videoBuilder;
  PlaybackSessionController? _session;
  StreamSubscription<PlaybackState>? _stateSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  int _loadGeneration = 0;
  bool _disposed = false;
  AnimeLibraryStore? _library;
  Duration _lastPosition = Duration.zero;
  bool _initialResumePending = true;
  bool _playing = false;
  bool _buffering = false;

  // 悬浮控制面板(右侧抽屉):选集 / 线路 / 设置。
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  int _panelTab = 0; // 0=选集 1=线路 2=设置
  double _rate = 1.0; // 倍速(跨集保持)
  BoxFit _fit = BoxFit.contain; // 画面填充

  // —— 手势与控件层(B站/YouTube 那套:全屏占满、点一下出控件、长按倍速快进)——
  // 明确**不做**双击快进/快退:issue #16 说了那个不好用。
  static const Duration _controlsIdle = Duration(seconds: 4);
  static const double _boostRate = 3.0;

  bool _controlsVisible = true;
  Timer? _controlsTimer;
  bool _boosting = false;
  Duration? _dragTarget; // 横向拖动定位时的预览位置
  Duration _dragOrigin = Duration.zero;
  bool _dragWasPlaying = false;
  bool _autoAdvanced = false;
  StreamSubscription<bool>? _completedSubscription;

  @override
  void initState() {
    super.initState();
    _enterImmersiveLandscape();
    final injected = widget.dependencies;
    if (injected != null) {
      _configurePlayback(
        adapter: injected.player,
        tracks: injected.tracks,
        loadTracks: injected.loadTracks,
        localTrackForEpisode: injected.localTrackForEpisode,
        videoBuilder: injected.videoBuilder,
      );
      unawaited(_load());
    } else {
      unawaited(_initializeNativePlayback());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _library = AnimeLibraryScope.maybeRead(context);
  }

  /// 进播放页即横屏 + 沉浸式全屏(仅移动端)。桌面窗口不动方向。
  void _enterImmersiveLandscape() {
    if (!Platform.isAndroid) return;
    unawaited(SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  }

  void _exitImmersiveLandscape() {
    if (!Platform.isAndroid) return;
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _controlsTimer?.cancel();
    _exitImmersiveLandscape();
    unawaited(_stateSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    final session = _session;
    if (session != null) {
      unawaited(session.dispose());
    } else {
      unawaited(_adapter?.dispose());
      unawaited(_nativePlayer?.dispose());
    }
    _source?.dispose();
    unawaited(_library?.flushPending());
    super.dispose();
  }

  Chapter get _ep => widget.episodes[_i];

  Future<void> _initializeNativePlayback() async {
    final player = Player(
      configuration: PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
        logLevel: kAvDiag ? MPVLogLevel.warn : MPVLogLevel.error,
        protocolWhitelist: MpvNetworkOptions.protocolWhitelist,
      ),
    );
    final videoController = VideoController(player);
    _nativePlayer = player;
    try {
      final cache = HlsCacheController.instance;
      await cache.initialize();
      if (_disposed) return;
      final dio = Dio();
      Future<List<VideoTrack>> loadTracks(String episodeId) async {
        final source = _source ??= buildSource(widget.meta);
        return source.getVideo(widget.animeId, episodeId);
      }

      VideoTrack? localTrackForEpisode(String episodeId) {
        final manifest = AnimeDownloadScope.maybeRead(context)?.localManifest(
          widget.meta.id,
          widget.animeId,
          episodeId,
        );
        if (manifest == null) return null;
        return VideoTrack(
          url: Uri.file(manifest, windows: Platform.isWindows).toString(),
          quality: '离线',
        );
      }

      final resolver = TrackResolver(
        fetchPlaylist: (uri, headers) async {
          final response = await dio.get<String>(
            uri.toString(),
            options: Options(
              headers: headers,
              responseType: ResponseType.plain,
            ),
          );
          return response.data ?? '';
        },
        refreshTracks: () => loadTracks(_ep.id),
      );
      final adapter = MediaKitPlayerAdapter(
        backend: NativeMediaKitBackend(player),
        gateway: cache.gateway,
        authScope: 'source:${widget.meta.id}',
      );
      _configurePlayback(
        adapter: adapter,
        tracks: resolver,
        loadTracks: (episodeId) async =>
            resolver.resolve(await loadTracks(episodeId)),
        localTrackForEpisode: localTrackForEpisode,
        videoBuilder: (fit) => Video(
          key: _videoKey,
          controller: videoController,
          fit: fit,
          controls: NoVideoControls,
        ),
      );
      await _load();
    } catch (error) {
      if (!_disposed && mounted) {
        setState(() => _playback = PlaybackState(
              phase: PlaybackPhase.failed,
              message: '播放器初始化失败：$error',
            ));
      }
    }
  }

  void _configurePlayback({
    required PlayerAdapter adapter,
    required PlaybackTrackProvider tracks,
    required Future<List<VideoTrack>> Function(String episodeId) loadTracks,
    required Widget Function(BoxFit fit) videoBuilder,
    VideoTrack? Function(String episodeId)? localTrackForEpisode,
  }) {
    _adapter = adapter;
    _loadTracks = loadTracks;
    _localTrackForEpisode = localTrackForEpisode;
    _videoBuilder = videoBuilder;
    final session = PlaybackSessionController(
      player: adapter,
      tracks: localTrackForEpisode == null
          ? tracks
          : _OfflineAwareTracks(
              delegate: tracks,
              localTrack: () => localTrackForEpisode(_ep.id),
            ),
      onProgress: _recordProgress,
      onPaused: () => unawaited(_library?.flushPending()),
    );
    _session = session;
    _stateSubscription = session.states.listen((state) {
      if (!mounted) return;
      setState(() {
        _playback = state;
        _current = state.selectedTrack;
      });
    });
    _playingSubscription = adapter.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
      // 播起来才自动隐藏控件;暂停时留着,免得用户找不到按钮。
      if (playing) {
        _scheduleHideControls();
      } else {
        _controlsTimer?.cancel();
        if (!_controlsVisible) setState(() => _controlsVisible = true);
      }
    });
    _bufferingSubscription = adapter.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => _buffering = buffering);
    });
    // 一集播完自动接下一集(番剧的默认期待,也顺带把历史推进到下一集)。
    // 用 _autoAdvanced 兜一层:后端在换源/重开时可能再报一次 completed,
    // 没有这道闸就会一口气跳过两集。
    _completedSubscription = adapter.completed.listen((completed) {
      if (!completed || !mounted || _disposed || _autoAdvanced) return;
      if (_i >= widget.episodes.length - 1) return;
      _autoAdvanced = true;
      _go(1);
    });
  }

  // ————————————————— 控件显隐 / 手势 —————————————————

  void _scheduleHideControls() {
    _controlsTimer?.cancel();
    if (!_playing) return;
    _controlsTimer = Timer(_controlsIdle, () {
      if (mounted && _playing && _dragTarget == null && !_boosting) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHideControls();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  /// 长按快进:按住 3 倍速播,松手回到用户选的倍速。比双击快进好用得多 ——
  /// 不打断画面、松手就回,长度也不是固定的 10 秒。
  void _startBoost() {
    if (_boosting || !_playing) return;
    setState(() => _boosting = true);
    unawaited(HapticFeedback.lightImpact());
    unawaited(_adapter?.setRate(_boostRate));
  }

  void _stopBoost() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    unawaited(_adapter?.setRate(_rate));
    _scheduleHideControls();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_playback.duration <= Duration.zero) return;
    _dragOrigin = _playback.position;
    _dragWasPlaying = _playing;
    setState(() {
      _dragTarget = _dragOrigin;
      _controlsVisible = true;
    });
    _controlsTimer?.cancel();
    if (_dragWasPlaying) unawaited(_adapter?.pause());
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details, double width) {
    final duration = _playback.duration;
    if (_dragTarget == null || duration <= Duration.zero || width <= 0) return;
    // 全屏宽 = 整段时长的 40%,长片也能一次拖到位,短片又不会一碰就飞。
    final deltaMs =
        details.delta.dx / width * duration.inMilliseconds.toDouble() * .4;
    final next = _dragTarget! + Duration(milliseconds: deltaMs.round());
    setState(() {
      _dragTarget = next < Duration.zero
          ? Duration.zero
          : next > duration
              ? duration
              : next;
    });
  }

  void _onHorizontalDragEnd() {
    final target = _dragTarget;
    if (target == null) return;
    setState(() => _dragTarget = null);
    unawaited(_session?.seekTo(target, resumeAfterSeek: _dragWasPlaying));
    _scheduleHideControls();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    _autoAdvanced = false;
    if (mounted) {
      setState(() => _playback = PlaybackState(
            phase: PlaybackPhase.resolving,
          ));
    }
    try {
      final local = _localTrackForEpisode?.call(_ep.id);
      final tracks = local == null ? await _loadTracks!(_ep.id) : [local];
      if (_disposed || generation != _loadGeneration) return;
      if (tracks.isEmpty) throw StateError('没有解析到可播放的线路');
      _tracks = tracks;
      final pick =
          tracks.firstWhere((track) => track.hls, orElse: () => tracks.first);
      final initialPosition =
          _initialResumePending ? widget.initialPosition : Duration.zero;
      _initialResumePending = false;
      await _session!.start(
        tracks,
        pick,
        initialPosition: initialPosition,
      );
      if (_disposed || generation != _loadGeneration) return;
      if (_rate != 1.0 && _session!.state.selectedTrack != null) {
        await _adapter!.setRate(_rate);
      }
    } catch (error) {
      if (!_disposed && generation == _loadGeneration && mounted) {
        setState(() => _playback = PlaybackState(
              phase: PlaybackPhase.failed,
              message: '$error',
            ));
      }
    }
  }

  void _go(int delta) => unawaited(_goTo(_i + delta));

  /// 跳到第 [index] 集(绝对)。越界/同集则忽略;换集后关面板。
  Future<void> _goTo(int index) async {
    if (index < 0 || index >= widget.episodes.length) return;
    _scaffoldKey.currentState?.closeEndDrawer();
    if (index == _i) return;
    await _library?.flushPending();
    if (_disposed) return;
    setState(() => _i = index);
    _lastPosition = Duration.zero;
    await _load();
  }

  void _recordProgress(Duration position, Duration duration) {
    _lastPosition = position;
    final library = _library;
    if (library == null) return;
    final episode = _ep;
    library.saveProgress(
      sourceId: widget.meta.id,
      animeId: widget.animeId,
      title: widget.animeTitle,
      episodeId: episode.id,
      episodeName: episode.name,
      episodeIndex: _i,
      position: position,
      duration: duration,
    );
  }

  /// 切线路 / 清晰度(与 _play 同逻辑,含错误兜底)。切完关面板。
  Future<void> _switchTrack(VideoTrack t) async {
    _scaffoldKey.currentState?.closeEndDrawer();
    if (t.url == _current?.url) return;
    final generation = ++_loadGeneration;
    try {
      await _session!.start(
        _tracks,
        t,
        initialPosition: _lastPosition,
      );
      if (_disposed || generation != _loadGeneration) return;
      _session!.setManualQualityLocked(true);
      if (_rate != 1.0) await _adapter!.setRate(_rate);
    } catch (error) {
      if (!_disposed && generation == _loadGeneration && mounted) {
        setState(() => _playback = PlaybackState(
              phase: PlaybackPhase.failed,
              message: '$error',
              selectedTrack: t,
              manualQualityLocked: true,
            ));
      }
    }
  }

  Future<void> _setRate(double r) async {
    setState(() => _rate = r);
    try {
      await _adapter?.setRate(r);
    } catch (_) {}
  }

  /// 选集网格用的短标签:优先用解析出的话数,否则用序号。
  String _epShort(int i) {
    final n = widget.episodes[i].number;
    if (n != null && n > 0) {
      return n == n.roundToDouble() ? '${n.round()}' : '$n';
    }
    return '${i + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      endDrawer: _controlPanel(p),
      // 手机上画面直接占满整屏:不再顶一条 AppBar、底下再压一条集导航条,
      // 所有 chrome 都浮在画面上,点一下出现、几秒后自动隐去。
      body: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            AnimePlaybackSurface(
              state: _playback,
              video: _videoBuilder?.call(_fit) ??
                  const ColoredBox(color: Colors.black),
              onRetry: _load,
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onLongPressStart: (_) => _startBoost(),
                onLongPressEnd: (_) => _stopBoost(),
                onLongPressCancel: _stopBoost,
                onHorizontalDragStart: _onHorizontalDragStart,
                onHorizontalDragUpdate: (details) =>
                    _onHorizontalDragUpdate(details, constraints.maxWidth),
                onHorizontalDragEnd: (_) => _onHorizontalDragEnd(),
                onHorizontalDragCancel: _onHorizontalDragEnd,
              ),
            ),
            if (_boosting) _boostBadge(),
            if (_dragTarget != null) _seekBadge(),
            _chrome(top: true, child: _topBar()),
            _chrome(top: false, child: _bottomBar()),
          ],
        ),
      ),
    );
  }

  /// 浮层 chrome:淡入淡出,隐藏时不吃点击(否则手势层收不到 tap)。
  Widget _chrome({required bool top, required Widget child}) => Positioned(
        left: 0,
        right: 0,
        top: top ? 0 : null,
        bottom: top ? null : 0,
        child: IgnorePointer(
          ignoring: !_controlsVisible,
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: child,
          ),
        ),
      );

  Widget _topBar() => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: Colors.white,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    '${widget.animeTitle} · ${_ep.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_current != null && _current!.quality.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(_current!.quality,
                        style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                IconButton(
                  tooltip: '选集 / 线路 / 设置',
                  icon: const Icon(Icons.playlist_play_rounded),
                  color: Colors.white,
                  onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _bottomBar() {
    final hasPrev = _i > 0;
    final hasNext = _i < widget.episodes.length - 1;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimePlayerControls(
              position: _dragTarget ?? _playback.position,
              duration: _playback.duration,
              playing: _playing,
              buffering: _buffering,
              onPlayPause: () {
                _showControls();
                if (_playing) {
                  _session?.setUserPaused(true);
                } else {
                  _session?.setUserPaused(false);
                  unawaited(_adapter?.play());
                }
              },
              onScrubStart: (wasPlaying) {
                _controlsTimer?.cancel();
                if (wasPlaying) unawaited(_adapter?.pause());
              },
              onSeek: (target, resumeAfterSeek) {
                _scheduleHideControls();
                unawaited(
                  _session?.seekTo(target, resumeAfterSeek: resumeAfterSeek),
                );
              },
              onOpenPanel: () => _scaffoldKey.currentState?.openEndDrawer(),
              onFullscreen: () =>
                  unawaited(_videoKey.currentState?.toggleFullscreen()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: hasPrev ? () => _go(-1) : null,
                    icon: const Icon(Icons.skip_previous_rounded, size: 18),
                    label: const Text('上一集'),
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.white70),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: hasNext ? () => _go(1) : null,
                    icon: const Icon(Icons.skip_next_rounded, size: 18),
                    label: const Text('下一集'),
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _boostBadge() => Align(
        alignment: const Alignment(0, -0.55),
        child: _PlayerBadge(
          key: const Key('player-boost-badge'),
          icon: Icons.fast_forward_rounded,
          label: '${_boostRate.toStringAsFixed(0)}x 快进中',
        ),
      );

  Widget _seekBadge() {
    final target = _dragTarget ?? Duration.zero;
    final delta = target - _dragOrigin;
    final sign = delta.isNegative ? '-' : '+';
    return Align(
      alignment: const Alignment(0, -0.55),
      child: _PlayerBadge(
        key: const Key('player-seek-badge'),
        icon: delta.isNegative
            ? Icons.fast_rewind_rounded
            : Icons.fast_forward_rounded,
        label: '${_formatClock(target)} / ${_formatClock(_playback.duration)}'
            '   $sign${_formatClock(delta.abs())}',
      ),
    );
  }

  static String _formatClock(Duration value) {
    final total = value.inSeconds.clamp(0, 359999);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final text = '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    return hours > 0 ? '$hours:$text' : text;
  }

  // ————————————————— 悬浮控制面板(右侧抽屉)—————————————————

  static const Color _panelBg = Color(0xFF161616);
  static const Color _panelChip = Color(0xFF2A2A2A);
  static const Color _accent = Color(0xFFFF6699); // B站粉,作选中高亮

  Widget _controlPanel(AppPalette p) {
    final width = MediaQuery.of(context).size.width;
    return Drawer(
      backgroundColor: _panelBg,
      width: width < 520 ? width * 0.82 : 360,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部分段:选集 / 线路 / 设置
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  _tabBtn('选集', 0),
                  _tabBtn('线路', 1),
                  _tabBtn('设置', 2),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: switch (_panelTab) {
                0 => _panelEpisodes(),
                1 => _panelTracks(),
                _ => _panelSettings(),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBtn(String label, int idx) {
    final on = _panelTab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _panelTab = idx),
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: on ? _accent.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: on ? _accent : Colors.white24, width: on ? 1.2 : 1),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  color: on ? _accent : Colors.white70,
                  fontSize: 13.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
        ),
      ),
    );
  }

  // —— 选集:话数网格 ——
  Widget _panelEpisodes() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 68,
        mainAxisExtent: 40,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: widget.episodes.length,
      itemBuilder: (_, i) {
        final on = i == _i;
        return Tooltip(
          message: widget.episodes[i].name,
          waitDuration: const Duration(milliseconds: 500),
          child: Material(
            color: on ? _accent.withValues(alpha: 0.20) : _panelChip,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _goTo(i),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: on ? Border.all(color: _accent, width: 1.2) : null,
                ),
                child: Text(_epShort(i),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: on ? _accent : Colors.white,
                        fontSize: 13,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
              ),
            ),
          ),
        );
      },
    );
  }

  // —— 线路 / 清晰度 ——
  Widget _panelTracks() {
    if (_tracks.isEmpty) {
      return const Center(
          child: Text('暂无可选线路',
              style: TextStyle(color: Colors.white38, fontSize: 13)));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _tracks.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: Colors.white10, indent: 16),
      itemBuilder: (_, i) {
        final t = _tracks[i];
        final on = t.url == _current?.url;
        return ListTile(
          dense: true,
          onTap: () => _switchTrack(t),
          leading: Icon(on ? Icons.check_circle_rounded : Icons.hd_outlined,
              color: on ? _accent : Colors.white38, size: 20),
          title: Text(t.quality.isEmpty ? '线路 ${i + 1}' : t.quality,
              style: TextStyle(
                  color: on ? _accent : Colors.white,
                  fontSize: 14,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
        );
      },
    );
  }

  // —— 设置:倍速 + 画面比例 ——
  Widget _panelSettings() {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    const fits = [
      ('适应', BoxFit.contain),
      ('填充', BoxFit.cover),
      ('拉伸', BoxFit.fill),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        const _PanelLabel('倍速播放'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in rates)
              _chip(r == 1.0 ? '1.0x' : '${r}x', _rate == r, () => _setRate(r)),
          ],
        ),
        const SizedBox(height: 24),
        const _PanelLabel('画面比例'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in fits)
              _chip(f.$1, _fit == f.$2, () => setState(() => _fit = f.$2)),
          ],
        ),
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? _accent.withValues(alpha: 0.18) : _panelChip,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? _accent : Colors.transparent),
        ),
        child: Text(label,
            style: TextStyle(
                color: on ? _accent : Colors.white70,
                fontSize: 13,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }
}

/// 画面中央的提示胶囊(长按快进 / 拖动定位)。
class _PlayerBadge extends StatelessWidget {
  const _PlayerBadge({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _PanelLabel extends StatelessWidget {
  const _PanelLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w700));
}
