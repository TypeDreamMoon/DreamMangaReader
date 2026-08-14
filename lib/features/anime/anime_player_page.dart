import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack; // 用本项目的 VideoTrack
import 'package:media_kit_video/media_kit_video.dart';
// media_kit_video 本来就依赖它(MaterialVideoControls 的亮度手势用的同一套),
// 这里提为直接依赖只是为了自己调用。安卓有原生实现,别的平台调了会抛,已 catch。
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../app/anime_download_store.dart';
import '../../app/anime_library_store.dart';
import '../../app/theme/app_colors.dart';
import 'anime_player_controls.dart';
import 'bili_failure_text.dart';
import 'playback/hls_cache_settings.dart';
import 'playback/media_kit_player_adapter.dart';
import 'playback/mpv_network_options.dart';
import 'playback/playback_messages.dart';
import 'playback/playback_session_controller.dart';
import 'playback/playback_state.dart';
import 'playback/player_adapter.dart';
import 'playback/subtitle_option.dart';
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
              Text(context.l10n.player_failed,
                  style: const TextStyle(
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
                label: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }

    final status = switch (state.phase) {
      PlaybackPhase.resolving => context.l10n.player_resolvingUrl,
      PlaybackPhase.opening => context.l10n.player_connecting,
      PlaybackPhase.buffering => context.l10n.player_buffering,
      PlaybackPhase.recovering => state.message ?? context.l10n.player_resuming,
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

  // 悬浮控制面板(右侧抽屉):选集 / 线路 / 字幕 / 设置。
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  int _panelTab = 0; // 0=选集 1=线路 2=字幕 3=设置
  double _rate = 1.0; // 倍速(跨集保持)
  BoxFit _fit = BoxFit.contain; // 画面填充

  // —— 字幕:源给的外挂 + 流里自带的内嵌,在 UI 上合成一个列表 ——
  List<SubtitleOption> _embedded = const [];
  SubtitleOption _subtitle = SubtitleOption.off;
  StreamSubscription<List<SubtitleOption>>? _subtitleSubscription;

  // —— 音量 / 亮度 ——
  // 音量走 mpv 的应用内音量(0–100),不动系统音量:跨平台一致,也不至于用户
  // 调完番剧音量,回头发现整机音量被改了。
  static const double _volumeStep = 5;
  double _volume = 100;
  double _volumeBeforeMute = 100;

  /// 应用级屏幕亮度(0–1),仅 Android 有实现;null = 取不到,亮度手势就不启用。
  double? _brightness;

  final FocusNode _focus = FocusNode(debugLabel: 'anime-player');

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

  // 竖向拖动 / 键盘调节时画面中央那个提示胶囊。
  _Adjustment? _adjusting;
  Timer? _adjustTimer;
  bool _adjustingBrightness = false;

  @override
  void initState() {
    super.initState();
    _enterImmersiveLandscape();
  }

  /// 开播放在这儿而不是 initState:整条链路要用 l10n(失败文案、恢复提示),
  /// 而 initState 里读不到 InheritedWidget。didChangeDependencies 在首帧构建时
  /// 就会跑,开播并不会因此变晚。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _library = AnimeLibraryScope.maybeRead(context);
    final l10n = context.l10n;
    _messages = PlaybackMessages(
      noRoute: l10n.player_noRoute,
      bufferTimeout: l10n.player_bufferTimeout,
      recovering: l10n.player_recovering,
      recoverFailed: l10n.player_recoverFailed,
    );
    // 语言切换会把这里再跑一遍,顺手把已开的会话换成新文案。
    _session?.messages = _messages!;
    if (_bootstrapped) return;
    _bootstrapped = true;
    unawaited(_initBrightness());
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

  PlaybackMessages? _messages;
  bool _bootstrapped = false;

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
    _adjustTimer?.cancel();
    _focus.dispose();
    _exitImmersiveLandscape();
    // 亮度是「应用级」的,退出播放页要还回去,否则整个 app 都留在这个亮度上。
    if (_brightness != null) {
      unawaited(ScreenBrightnessPlatform.instance
          .resetApplicationScreenBrightness()
          .catchError((_) {}));
    }
    unawaited(_stateSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    unawaited(_subtitleSubscription?.cancel());
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
          quality: context.l10n.anime_offline,
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
              message: context.l10n.player_initFailed('$error'),
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
      messages: _messages!,
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
    // 内嵌字幕是 mpv 解析出文件头之后才报上来的,所以只能听着来,不能开播时问一次。
    _subtitleSubscription = adapter.subtitles.listen((options) {
      if (!mounted) return;
      setState(() => _embedded = options);
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

  // ————————————————— 音量 / 亮度 —————————————————

  /// 读一次当前的应用级亮度。读不到(桌面没有原生实现)就把亮度手势关掉,
  /// 免得左半屏拖半天没反应。
  Future<void> _initBrightness() async {
    if (!Platform.isAndroid) return;
    try {
      final value = await ScreenBrightnessPlatform.instance.application;
      if (mounted) setState(() => _brightness = value.clamp(0.0, 1.0));
    } on Object {
      // 没有实现 / 被系统拒绝:保持 null,亮度手势不启用。
    }
  }

  void _setVolume(double value, {bool showBadge = true}) {
    final next = value.clamp(0.0, 100.0);
    setState(() => _volume = next);
    unawaited(_adapter?.setVolume(next));
    if (showBadge) {
      _showAdjustment(_Adjustment(
        icon: next <= 0
            ? Icons.volume_off_rounded
            : next < 50
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
        label: next <= 0
            ? context.l10n.player_muted
            : context.l10n.player_volume,
        value: next / 100,
      ));
    }
  }

  void _toggleMute() {
    if (_volume > 0) {
      _volumeBeforeMute = _volume;
      _setVolume(0);
    } else {
      _setVolume(_volumeBeforeMute <= 0 ? 100 : _volumeBeforeMute);
    }
  }

  void _setBrightness(double value) {
    final next = value.clamp(0.0, 1.0);
    setState(() => _brightness = next);
    unawaited(
      ScreenBrightnessPlatform.instance
          .setApplicationScreenBrightness(next)
          .catchError((_) {}),
    );
    _showAdjustment(_Adjustment(
      icon: next < 0.34
          ? Icons.brightness_low_rounded
          : next < 0.67
              ? Icons.brightness_medium_rounded
              : Icons.brightness_high_rounded,
      label: context.l10n.player_brightness,
      value: next,
    ));
  }

  void _showAdjustment(_Adjustment adjustment) {
    setState(() => _adjusting = adjustment);
    _adjustTimer?.cancel();
    _adjustTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _adjusting = null);
    });
  }

  // —— 竖向拖动:左半屏亮度、右半屏音量(B站/YouTube 那套)——
  // 亮度没实现的平台上整屏都归音量,总比左半边是块死区强。
  void _onVerticalDragStart(DragStartDetails details, double width) {
    _adjustingBrightness =
        _brightness != null && details.localPosition.dx < width / 2;
    _controlsTimer?.cancel();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double height) {
    if (height <= 0) return;
    // 六成屏高走完整个量程:再灵敏一点就容易手一抖静音。
    final delta = -details.delta.dy / (height * 0.6);
    if (_adjustingBrightness) {
      _setBrightness((_brightness ?? 0) + delta);
    } else {
      _setVolume(_volume + delta * 100);
    }
  }

  void _onVerticalDragEnd() => _scheduleHideControls();

  void _onPointerSignal(PointerSignalEvent event) {
    // 桌面滚轮 = 音量,和大多数播放器一致。
    if (event is! PointerScrollEvent) return;
    _setVolume(_volume - event.scrollDelta.dy.sign * _volumeStep);
  }

  // ————————————————— 键盘(桌面)—————————————————

  void _togglePlay() {
    _showControls();
    if (_playing) {
      _session?.setUserPaused(true);
    } else {
      _session?.setUserPaused(false);
      unawaited(_adapter?.play());
    }
  }

  void _seekBy(int seconds) {
    final duration = _playback.duration;
    if (duration <= Duration.zero) return;
    final requested = _playback.position + Duration(seconds: seconds);
    final target = requested < Duration.zero
        ? Duration.zero
        : requested > duration
            ? duration
            : requested;
    unawaited(_session?.seekTo(target, resumeAfterSeek: _playing));
    _showControls();
  }

  /// 桌面快捷键。N/P 换集刻意和漫画阅读器的 N/P 换章对齐。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _setVolume(_volume + _volumeStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _setVolume(_volume - _volumeStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyF) {
      unawaited(_videoKey.currentState?.toggleFullscreen());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyN) {
      if (_i < widget.episodes.length - 1) _go(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyP) {
      if (_i > 0) _go(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      // 面板开着就先收面板 —— Esc 一路退到底会把人直接踢出播放页。
      final scaffold = _scaffoldKey.currentState;
      if (scaffold?.isEndDrawerOpen ?? false) {
        scaffold!.closeEndDrawer();
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    _autoAdvanced = false;
    if (mounted) {
      setState(() {
        _playback = PlaybackState(phase: PlaybackPhase.resolving);
        // 新的一集是新的一套轨道,旧的选择连同旧的内嵌列表一起作废。
        _subtitle = SubtitleOption.off;
        _embedded = const [];
      });
    }
    try {
      final local = _localTrackForEpisode?.call(_ep.id);
      final tracks = local == null ? await _loadTracks!(_ep.id) : [local];
      if (_disposed || generation != _loadGeneration) return;
      if (tracks.isEmpty) throw StateError(_messages!.noRoute);
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
              message: describeSourceError(context, error),
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
      // 换清晰度是同一集换个流:外挂字幕(标识是 URL)照旧有效,挂回去。
      // 内嵌轨道号是 mpv 按流现编的,不能跨流复用,交给新流的默认。
      if (_subtitle.isExternal) await _adapter!.setSubtitle(_subtitle);
    } catch (error) {
      if (!_disposed && generation == _loadGeneration && mounted) {
        setState(() => _playback = PlaybackState(
              phase: PlaybackPhase.failed,
              message: describeSourceError(context, error),
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
      // 抽屉会把焦点抢走,收回来时得还给播放页,否则开过一次面板之后快捷键就哑了。
      onEndDrawerChanged: (opened) {
        if (!opened && mounted) _focus.requestFocus();
      },
      // 手机上画面直接占满整屏:不再顶一条 AppBar、底下再压一条集导航条,
      // 所有 chrome 都浮在画面上,点一下出现、几秒后自动隐去。
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
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
                child: Listener(
                  onPointerSignal: _onPointerSignal,
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
                    onVerticalDragStart: (details) =>
                        _onVerticalDragStart(details, constraints.maxWidth),
                    onVerticalDragUpdate: (details) =>
                        _onVerticalDragUpdate(details, constraints.maxHeight),
                    onVerticalDragEnd: (_) => _onVerticalDragEnd(),
                    onVerticalDragCancel: _onVerticalDragEnd,
                  ),
                ),
              ),
              if (_boosting) _boostBadge(),
              if (_dragTarget != null) _seekBadge(),
              if (_adjusting != null) _adjustBadge(_adjusting!),
              _chrome(top: true, child: _topBar()),
              _chrome(top: false, child: _bottomBar()),
            ],
          ),
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

  /// 顶栏标题。分集名里常常已经带了番剧名(源给的就是「龙与虎」这种),
  /// 再拼一次就成了「龙与虎 · 第1话 龙与虎」。带了就只显示分集名。
  String get _headline {
    final title = widget.animeTitle.trim();
    final episode = _ep.name.trim();
    if (title.isEmpty) return episode;
    if (episode.isEmpty) return title;
    return episode.contains(title) ? episode : '$title · $episode';
  }

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
                  tooltip: context.l10n.player_back,
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: Colors.white,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    _headline,
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
                  tooltip: context.l10n.player_menuTooltip,
                  icon: const Icon(Icons.playlist_play_rounded),
                  color: Colors.white,
                  onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                ),
              ],
            ),
          ),
        ),
      );

  /// 底部 chrome。**只有这一层画底** —— 一整块从下往上淡出的渐变,控件浮在上面。
  /// 控件自己再铺一块实心底,就会在渐变上留一道硬缝。
  Widget _bottomBar() => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xE6000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: AnimePlayerControls(
              position: _dragTarget ?? _playback.position,
              duration: _playback.duration,
              playing: _playing,
              buffering: _buffering,
              onPlayPause: _togglePlay,
              onPrevEpisode: _i > 0 ? () => _go(-1) : null,
              onNextEpisode:
                  _i < widget.episodes.length - 1 ? () => _go(1) : null,
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
          ),
        ),
      );

  Widget _boostBadge() => Align(
        alignment: const Alignment(0, -0.55),
        child: _PlayerBadge(
          key: const Key('player-boost-badge'),
          icon: Icons.fast_forward_rounded,
          label: context.l10n.player_boosting(_boostRate.toStringAsFixed(0)),
        ),
      );

  Widget _adjustBadge(_Adjustment adjustment) => Align(
        alignment: const Alignment(0, -0.55),
        child: _PlayerBadge(
          key: const Key('player-adjust-badge'),
          icon: adjustment.icon,
          label: '${adjustment.label}   '
              '${(adjustment.value * 100).round()}%',
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

  // 面板底色不跟主题走:画面是黑的,浮在上面的面板也必须是暗的,否则浅色主题下
  // 会在夜里糊人一脸白。选中高亮才跟主题走 —— 见 [_accent]。
  static const Color _panelBg = Color(0xFF161616);
  static const Color _panelChip = Color(0xFF2A2A2A);

  /// 选中高亮。跟随全局主题色,但因为面板底恒为近黑,暗色系强调色要先抬到可读。
  Color get _accent => ensureContrast(context.palette.accent, _panelBg);

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
            // 顶部分段:选集 / 线路 / 字幕 / 设置
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  _tabBtn(context.l10n.player_tabEpisodes, 0),
                  _tabBtn(context.l10n.player_tabRoutes, 1),
                  _tabBtn(context.l10n.player_tabSubtitles, 2),
                  _tabBtn(context.l10n.player_tabSettings, 3),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: switch (_panelTab) {
                0 => _panelEpisodes(),
                1 => _panelTracks(),
                2 => _panelSubtitles(),
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
    final accent = _accent;
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
            color: on ? accent.withValues(alpha: 0.20) : _panelChip,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _goTo(i),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: on ? Border.all(color: accent, width: 1.2) : null,
                ),
                child: Text(_epShort(i),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: on ? accent : Colors.white,
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
      return Center(
          child: Text(context.l10n.player_noRoutes,
              style: const TextStyle(color: Colors.white38, fontSize: 13)));
    }
    final accent = _accent;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _tracks.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: Colors.white10, indent: 16),
      itemBuilder: (_, i) {
        final t = _tracks[i];
        final on = t.url == _current?.url;
        return _panelRow(
          accent: accent,
          selected: on,
          icon: on ? Icons.check_circle_rounded : Icons.hd_outlined,
          label:
              t.quality.isEmpty ? context.l10n.player_routeN(i + 1) : t.quality,
          onTap: () => _switchTrack(t),
        );
      },
    );
  }

  // —— 字幕:源给的外挂 + 流里自带的内嵌,合成一张表 ——
  //
  // 两者对用户是一回事(「这一集有哪些字幕」),对播放器却是两条路,所以合并只在
  // 这里做,不往下渗到 playback/。
  Widget _panelSubtitles() {
    final l10n = context.l10n;
    final options = <SubtitleOption>[
      for (final asset in _current?.subtitles ?? const <SubtitleAsset>[])
        SubtitleOption.asset(asset),
      ..._embedded,
    ];
    if (options.isEmpty) {
      return Center(
          child: Text(l10n.player_noSubtitles,
              style: const TextStyle(color: Colors.white38, fontSize: 13)));
    }
    final accent = _accent;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: options.length + 1, // +1 = 置顶的「关闭字幕」
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: Colors.white10, indent: 16),
      itemBuilder: (_, i) {
        if (i == 0) {
          final on = _subtitle.isOff;
          return _panelRow(
            accent: accent,
            selected: on,
            icon: on ? Icons.check_circle_rounded : Icons.subtitles_off_outlined,
            label: l10n.player_subtitleOff,
            onTap: () => _setSubtitle(SubtitleOption.off),
          );
        }
        final option = options[i - 1];
        final on = option == _subtitle;
        return _panelRow(
          accent: accent,
          selected: on,
          icon: on ? Icons.check_circle_rounded : Icons.subtitles_outlined,
          label: option.label.isEmpty
              ? l10n.player_subtitleN(i)
              : option.label,
          onTap: () => _setSubtitle(option),
        );
      },
    );
  }

  Widget _panelRow({
    required Color accent,
    required bool selected,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      ListTile(
        dense: true,
        onTap: onTap,
        leading:
            Icon(icon, color: selected ? accent : Colors.white38, size: 20),
        title: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: selected ? accent : Colors.white,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      );

  Future<void> _setSubtitle(SubtitleOption option) async {
    _scaffoldKey.currentState?.closeEndDrawer();
    setState(() => _subtitle = option);
    try {
      await _adapter?.setSubtitle(option);
    } on Object {
      // 挂不上就算了,画面照播。
    }
  }

  // —— 设置:倍速 + 画面比例 ——
  Widget _panelSettings() {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final fits = [
      (context.l10n.player_fitContain, BoxFit.contain),
      (context.l10n.player_fitCover, BoxFit.cover),
      (context.l10n.player_fitStretch, BoxFit.fill),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _PanelLabel(context.l10n.player_speed),
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
        _PanelLabel(context.l10n.player_aspect),
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
    final accent = _accent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.18) : _panelChip,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? accent : Colors.transparent),
        ),
        child: Text(label,
            style: TextStyle(
                color: on ? accent : Colors.white70,
                fontSize: 13,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }
}

/// 竖向拖动 / 键盘调节音量亮度时,中央胶囊要显示的一次读数。
class _Adjustment {
  const _Adjustment({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;

  /// 0–1,展示成百分比。
  final double value;
}

/// 画面中央的提示胶囊(长按快进 / 拖动定位 / 音量亮度)。
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
