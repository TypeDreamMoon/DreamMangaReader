import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack; // 用本项目的 VideoTrack
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/anime_library_store.dart';
import '../../app/local_media_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/local/local_models.dart';
import '../../core/platform/local_media_bridge.dart';
import '../../core/platform/window_fullscreen.dart';
import '../../core/source/models.dart';
import '../anime/anime_player_controls.dart';
import '../anime/playback/media_kit_player_adapter.dart';
import '../anime/playback/playback_messages.dart';
import '../anime/playback/playback_session_controller.dart';
import '../anime/playback/playback_state.dart';
import '../anime/playback/player_adapter.dart';
import '../anime/playback/subtitle_option.dart';
import 'local_player_adapter.dart';
import 'local_track.dart';
import 'local_track_provider.dart';

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

/// 本地文件播放页。与番剧播放页共用控制条与播放会话,但整条链路不碰网络。
///
/// 三条与番剧页的关键差别(规格 §6.2):
/// 1. 用 [LocalPlayerAdapter] 而不是 `MediaKitPlayerAdapter` —— 后者会无条件调
///    `backend.configure()` 给 mpv 设网络参数。
/// 2. `PlayerConfiguration` 不传 `protocolWhitelist`,`bufferSize` 降到 8 MiB
///    (番剧是 64 MiB):本地文件不需要预读那么多。
/// 3. 断点走 `open(startAt:)`(会话控制器内部已经这么做),不 open 后再 seek。
///
/// Android 的条目位置是 `content://` URI,播放前必须经
/// [LocalMediaBridge.openFd] 换成 `/proc/self/fd/N`(规格 §7.2 路线 A);
/// 换来的 fd 要在换集/退出时才释放。
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
  static const _loopModeKey = 'anime.player.loopMode';
  static const _autoPlayKey = 'anime.player.autoPlay';
  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _videoKey = GlobalKey();

  Player? _player;
  PlayerAdapter? _adapter;
  LocalTrackProvider? _tracks;
  PlaybackSessionController? _session;
  Widget Function(BoxFit fit)? _videoBuilder;

  StreamSubscription<PlaybackState>? _stateSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<List<SubtitleOption>>? _subtitleSubscription;
  StreamSubscription<bool>? _completedSubscription;

  PlaybackMessages? _messages;
  AnimeLibraryStore? _library;
  LocalMediaStore? _media;
  LocalMediaBridge? _bridge;

  PlaybackState _playback = const PlaybackState.idle();
  List<SubtitleOption> _embedded = const [];
  SubtitleOption _subtitle = SubtitleOption.off;

  /// Android 上由 [LocalMediaBridge.openFd] 换出来的 fd,退出/换集时释放。
  final List<int> _openFds = [];

  int _i = 0;
  int _loadGeneration = 0;
  Duration _lastPosition = Duration.zero;
  Duration? _dragTarget;
  Offset _doubleTapAt = Offset.zero;

  bool _playing = false;
  bool _buffering = false;
  bool _controlsVisible = true;
  bool _bootstrapped = false;
  bool _disposed = false;
  bool _autoAdvanced = false;
  bool _loopSingle = false;
  bool _autoPlay = true;
  double _rate = 1.0;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _i = widget.initialIndex.clamp(0, widget.items.length - 1);
    _lastPosition = widget.initialPosition;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _library = AnimeLibraryScope.maybeRead(context);
    _media = LocalMediaScope.read(context);
    final l10n = context.l10n;
    _messages = PlaybackMessages(
      // 本地场景没有「解析不出线路」这回事,这句只可能是文件不可读。
      noRoute: l10n.local_playbackFailed,
      bufferTimeout: l10n.player_bufferTimeout,
      recovering: l10n.player_recovering,
      recoverFailed: l10n.player_recoverFailed,
    );
    _session?.messages = _messages!;
    if (_bootstrapped) return;
    _bootstrapped = true;
    _enterImmersiveLandscape();
    unawaited(_loadPreferences());
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _controlsTimer?.cancel();
    unawaited(_stateSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    unawaited(_subtitleSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    unawaited(_flushProgress());
    unawaited(_releaseFds());
    unawaited(_session?.dispose());
    // 注入了 player 就由注入方负责它的生命周期,页面不越权 dispose。
    if (widget.dependencies == null) {
      unawaited(_adapter?.dispose());
      unawaited(_player?.dispose());
    }
    unawaited(WakelockPlus.disable().catchError((_) {}));
    _exitImmersiveLandscape();
    super.dispose();
  }

  LocalMediaItem get _item => widget.items[_i];

  /// 还有下一集吗:自动连播、「下一集」按钮与失败页跳集共用同一处边界判断。
  bool get _hasNext => _i < widget.items.length - 1;

  // —— 平台外观 ——

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

  Future<void> _loadPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      final mode = preferences.getString(_loopModeKey);
      setState(() {
        _loopSingle = mode == 'single';
        _autoPlay = preferences.getBool(_autoPlayKey) ?? true;
      });
    } on Object {
      // 读设置失败就用默认值,不该拦住播放。
    }
  }

  // —— 播放链路 ——

  /// 把条目变成「播放层能打开的位置」。
  ///
  /// Android 的 SAF 授权只给出 `content://` URI,而 mpv 只认文件路径:经桥换成
  /// `/proc/self/fd/N`(规格 §7.2 路线 A)。fd 在换集/退出时才释放 —— 提前释放会
  /// 让正在读的文件变成「已关闭的 fd」。
  Future<LocalMediaItem> _playableItem(LocalMediaItem item) async {
    if (!item.location.startsWith('content://')) return item;
    final bridge = _bridge ??= widget.bridge ?? LocalMediaBridge();
    final opened = await bridge.openFd(item.location);
    _openFds.add(opened.fd);
    final subtitles = <LocalSubtitle>[];
    for (final subtitle in item.subtitles) {
      if (!subtitle.location.startsWith('content://')) {
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
    return item.copyWith(location: opened.path, subtitles: subtitles);
  }

  /// 建会话(第一次)或把当前文件换给既有会话。
  PlaybackSessionController _sessionFor(VideoTrack track) {
    final existing = _session;
    if (existing != null) {
      _tracks!.track = track;
      return existing;
    }
    final injected = widget.dependencies;
    if (injected != null) {
      _adapter = injected.player;
      _videoBuilder = injected.videoBuilder;
    } else {
      final player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 8 * 1024 * 1024,
          // 不传 protocolWhitelist:那是给 HTTP/HLS 用的,本地文件不需要。
          logLevel: MPVLogLevel.error,
        ),
      );
      final controller = VideoController(player);
      _player = player;
      _adapter = LocalPlayerAdapter(
        NativeMediaKitBackend(player),
        track: track,
      );
      _videoBuilder = (fit) => Video(
        key: _videoKey,
        controller: controller,
        fit: fit,
        // 值本身就是 null(不要 mpv 自带控件,我们用自己的控制条);显式标注掉
        // 无类型注解的 null 造成的隐式下转。
        controls: NoVideoControls as VideoControlsBuilder?,
      );
    }
    final provider = LocalTrackProvider(track);
    _tracks = provider;
    final session = PlaybackSessionController(
      player: _adapter!,
      tracks: provider,
      messages: _messages!,
      onProgress: _recordProgress,
      onPaused: () => unawaited(_flushProgress()),
    );
    _session = session;
    _bind(session, _adapter!);
    return session;
  }

  void _bind(PlaybackSessionController session, PlayerAdapter adapter) {
    _stateSubscription = session.states.listen((state) {
      if (!mounted) return;
      setState(() => _playback = state);
    });
    _playingSubscription = adapter.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
      if (playing) {
        unawaited(WakelockPlus.enable().catchError((_) {}));
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
    // 内嵌字幕要等 mpv 读完文件头才报上来,只能听着,不能开播时问一次。
    _subtitleSubscription = adapter.subtitles.listen((options) {
      if (!mounted) return;
      setState(() => _embedded = options);
    });
    _completedSubscription = adapter.completed.listen((completed) {
      if (!completed || !mounted || _disposed || _autoAdvanced) return;
      _autoAdvanced = true;
      if (_loopSingle) {
        unawaited(_reload());
      } else if (_autoPlay && _hasNext) {
        unawaited(_goTo(_i + 1));
      }
    });
  }

  /// 播这一集:解析位置 → 建 track → 开会话。
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    // 文案在 await 之前取好:后面跨了异步再读 context 会被 lint 拦(而且此时
    // 也可能已经不在树上)。
    final l10n = context.l10n;
    _autoAdvanced = false;
    if (mounted) {
      setState(() {
        _playback = const PlaybackState(phase: PlaybackPhase.resolving);
        // 换集=换文件:上一集的内嵌轨道号在新文件里指向别的东西。
        _subtitle = SubtitleOption.off;
        _embedded = const [];
      });
    }
    try {
      final item = _item;
      final playable = await _playableItem(item);
      if (_loadExpired(generation)) return;
      final track = buildLocalTrack(
        playable,
        qualityLabel: l10n.local_qualityLocal,
      );
      final session = _sessionFor(track);
      await session.start([track], track, initialPosition: _resumeFor(item));
      if (_loadExpired(generation)) return;
      if (_rate != 1.0) {
        await _adapter?.setRate(_rate);
      }
    } on Object catch (error) {
      if (_loadExpired(generation) || !mounted) return;
      setState(() => _playback = PlaybackState(
            phase: PlaybackPhase.failed,
            message: l10n.local_openFailed('$error'),
          ));
    }
  }

  Future<void> _reload() async {
    _lastPosition = Duration.zero;
    await _load();
  }

  /// 这次加载是否已经作废:页面已销毁,或期间又发起了新一次加载。
  bool _loadExpired(int generation) =>
      _disposed || generation != _loadGeneration;

  /// 这一集该从哪儿开始:库详情页带来的断点优先,其次读历史。
  Duration _resumeFor(LocalMediaItem item) {
    if (widget.initialIndex == _i && widget.initialPosition > Duration.zero) {
      return widget.initialPosition;
    }
    final entry = _library?.historyFor(LocalSource.id, widget.library.id);
    if (entry == null || entry.episodeId != item.id) return Duration.zero;
    return Duration(seconds: entry.positionSeconds);
  }

  void _recordProgress(Duration position, Duration duration) {
    _lastPosition = position;
    final library = _library;
    if (library == null) return;
    final item = _item;
    library.saveProgress(
      sourceId: LocalSource.id,
      animeId: widget.library.id,
      title: widget.library.name,
      episodeId: item.id,
      episodeName: item.title,
      episodeIndex: _i,
      position: position,
      duration: duration,
    );
  }

  /// 暂停 / 切集 / 退出时把进度落到盘上(与番剧页同款 `flushPending` 模式)。
  Future<void> _flushProgress() async {
    await _library?.flushPending();
    try {
      await _media?.markPlayed(
        _item.id,
        position: _lastPosition,
        duration: _playback.duration,
      );
    } on Object {
      // 最近播放没记上不影响看。
    }
  }

  Future<void> _releaseFds() async {
    if (_openFds.isEmpty) return;
    final bridge = _bridge ?? widget.bridge;
    final fds = List<int>.from(_openFds);
    _openFds.clear();
    if (bridge == null) return;
    for (final fd in fds) {
      try {
        await bridge.releaseFd(fd);
      } on Object {
        // 幂等:重复释放或已随进程关闭都不算错。
      }
    }
  }

  Future<void> _goTo(int index) async {
    if (index < 0 || index >= widget.items.length || index == _i) return;
    await _flushProgress();
    await _releaseFds();
    if (_disposed) return;
    setState(() {
      _i = index;
      _lastPosition = Duration.zero;
      _controlsVisible = true;
    });
    await _load();
  }

  // —— 控制条行为 ——

  void _togglePlay() {
    final adapter = _adapter;
    if (adapter == null) return;
    final session = _session;
    if (_playing) {
      session?.setUserPaused(true);
    } else {
      session?.setUserPaused(false);
      unawaited(adapter.play());
    }
    _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_playing) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  void _handleDoubleTap() {
    final width = context.size?.width ?? 0;
    final left = width == 0 || _doubleTapAt.dx < width / 2;
    final position = _playback.position;
    final target = left
        ? position - const Duration(seconds: 15)
        : position + const Duration(seconds: 15);
    final clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(
        0,
        _playback.duration.inMilliseconds > 0
            ? _playback.duration.inMilliseconds
            : position.inMilliseconds,
      ),
    );
    unawaited(_session?.seekTo(clamped, resumeAfterSeek: _playing));
  }

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    try {
      await _adapter?.setRate(rate);
    } on Object {
      // 倍速没设上不该弹错。
    }
  }

  Future<void> _setSubtitle(SubtitleOption option) async {
    Navigator.of(context).maybePop();
    setState(() => _subtitle = option);
    try {
      await _adapter?.setSubtitle(option);
    } on Object {
      // 挂不上字幕画面照播。
    }
  }

  void _toggleFullscreen() {
    WindowFullscreen.instance.toggle();
    setState(() {});
  }

  // —— 面板 ——

  List<SubtitleOption> get _subtitleOptions => [
        for (final asset in _tracks?.track.subtitles ?? const <SubtitleAsset>[])
          SubtitleOption.asset(asset),
        ..._embedded,
      ];

  /// 面板底色:播放页恒为深色,不跟主题走。
  static const Color _sheetBg = Color(0xFF161616);

  /// 三个面板共用的外壳:统一底色与标题行,并在开面板前停掉控制条自动隐藏、
  /// 收起后重新计时。
  ///
  /// [builder] 拿到的是弹层自己的 context —— 面板里要 pop 就用它,别用页面的。
  Future<void> _showSheet({
    required String title,
    required Widget Function(BuildContext sheetContext) builder,
  }) async {
    _controlsTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _sheetBg,
      builder: (sheetContext) =>
          _sheet(title: title, child: builder(sheetContext)),
    );
    if (mounted) _scheduleHideControls();
  }

  Future<void> _showEpisodesSheet() {
    final current = _i;
    return _showSheet(
      title: context.l10n.local_episodeList,
      builder: (sheetContext) => ListView.builder(
        shrinkWrap: true,
        itemCount: widget.items.length,
        itemBuilder: (_, index) {
          final item = widget.items[index];
          final selected = index == current;
          return _sheetRow(
            label: '${index + 1}. ${item.title}',
            selected: selected,
            icon: selected
                ? Icons.play_circle_fill_rounded
                : Icons.play_circle_outline,
            onTap: () {
              Navigator.of(sheetContext).maybePop();
              unawaited(_goTo(index));
            },
          );
        },
      ),
    );
  }

  Future<void> _showSubtitleSheet() {
    final options = _subtitleOptions;
    return _showSheet(
      title: context.l10n.local_subtitles,
      builder: (_) => options.isEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 22),
              child: Text(
                context.l10n.player_noSubtitles,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            )
          : ListView.builder(
              shrinkWrap: true,
              itemCount: options.length + 1,
              itemBuilder: (_, index) {
                if (index == 0) {
                  return _sheetRow(
                    label: context.l10n.local_subtitleOff,
                    selected: _subtitle.isOff,
                    icon: Icons.subtitles_off_outlined,
                    onTap: () => unawaited(_setSubtitle(SubtitleOption.off)),
                  );
                }
                final option = options[index - 1];
                return _sheetRow(
                  label: option.label.isEmpty
                      ? context.l10n.player_subtitleN(index)
                      : option.label,
                  selected: option == _subtitle,
                  icon: Icons.subtitles_outlined,
                  onTap: () => unawaited(_setSubtitle(option)),
                );
              },
            ),
    );
  }

  Future<void> _showRateSheet() {
    return _showSheet(
      title: context.l10n.local_speed,
      builder: (sheetContext) => ListView.builder(
        shrinkWrap: true,
        itemCount: _rates.length,
        itemBuilder: (_, index) {
          final rate = _rates[index];
          return _sheetRow(
            label: rate == 1.0 ? '1.0x' : '${rate}x',
            selected: _rate == rate,
            icon: Icons.speed_rounded,
            onTap: () {
              Navigator.of(sheetContext).maybePop();
              unawaited(_setRate(rate));
            },
          );
        },
      ),
    );
  }

  Widget _sheet({required String title, required Widget child}) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Flexible(child: child),
          ],
        ),
      );

  Widget _sheetRow({
    required String label,
    required bool selected,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final accent = ensureContrast(context.palette.accent, _sheetBg);
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(icon, color: selected ? accent : Colors.white38, size: 20),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: selected ? accent : Colors.white,
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  // —— 画面 ——

  @override
  Widget build(BuildContext context) {
    final builder = _videoBuilder;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (builder != null)
            builder(BoxFit.contain)
          else
            const ColoredBox(color: Colors.black),
          _gestureLayer(),
          if (_playback.phase == PlaybackPhase.failed) _failureLayer(),
          if (_buffering && _playback.phase != PlaybackPhase.failed)
            const Center(
              child: SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
            ),
          if (_dragTarget != null) _seekPreview(),
          if (_controlsVisible) _chrome(),
        ],
      ),
    );
  }

  Widget _gestureLayer() => Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
          onDoubleTap: _handleDoubleTap,
          onHorizontalDragStart: (details) {
            _controlsTimer?.cancel();
            setState(() => _dragTarget = _playback.position);
          },
          onHorizontalDragUpdate: (details) {
            final width = context.size?.width ?? 1;
            final delta = details.primaryDelta ?? 0;
            final span = _playback.duration.inMilliseconds;
            if (span <= 0) return;
            final current = _dragTarget ?? _playback.position;
            final next = current.inMilliseconds + (delta / width) * span;
            setState(() {
              _dragTarget = Duration(
                milliseconds: next.round().clamp(0, span),
              );
            });
          },
          onHorizontalDragEnd: (_) {
            final target = _dragTarget;
            setState(() => _dragTarget = null);
            if (target == null) return;
            unawaited(_session?.seekTo(target, resumeAfterSeek: _playing));
          },
        ),
      );

  Widget _chrome() {
    final accent = context.palette.accent;
    return Stack(
      fit: StackFit.expand,
      children: [
        _topChrome(),
        _bottomChrome(),
        // 恢复/失败提示:压在画面上方偏上,不挡控制条。
        if ((_playback.message ?? '').isNotEmpty &&
            _playback.phase != PlaybackPhase.failed)
          Positioned(
            top: 72,
            left: 24,
            right: 24,
            child: Text(
              _playback.message!,
              textAlign: TextAlign.center,
              style: TextStyle(color: accent, fontSize: 12.5),
            ),
          ),
      ],
    );
  }

  /// 顶部栏:返回键 + 标题 + 集数,压在自上而下的渐变上。
  Widget _topChrome() => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: Colors.white),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${widget.library.name} · ${_i + 1}/${widget.items.length}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      );

  /// 底部栏:控制条,压在自下而上的渐变上。
  Widget _bottomChrome() => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
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
                buffered: _playback.buffered,
                playing: _playing,
                buffering: _buffering,
                onPlayPause: _togglePlay,
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
                onOpenPanel: () => unawaited(_showSubtitleSheet()),
                onEpisodes: widget.items.length > 1
                    ? () => unawaited(_showEpisodesSheet())
                    : null,
                onRate: () => unawaited(_showRateSheet()),
                rateLabel: _rate == 1.0 ? '' : '${_rate}x',
                // 本地文件没有清晰度/线路可言:传 null 按钮就不出现。
                onQuality: null,
                qualityLabel: context.l10n.local_qualityLocal,
                onPrevEpisode: _i > 0 ? () => unawaited(_goTo(_i - 1)) : null,
                onNextEpisode: _hasNext
                    ? () => unawaited(_goTo(_i + 1))
                    : null,
                // 移动端播放页本来就占满屏,再给全屏键只会点了没反应。
                onFullscreen:
                    WindowFullscreen.supported ? _toggleFullscreen : null,
                fullscreen: WindowFullscreen.instance.isFullscreen,
              ),
            ),
          ),
        ),
      );

  Widget _seekPreview() {
    final target = _dragTarget!;
    final duration = _playback.duration;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            duration > Duration.zero
                ? '${_timeLabel(target)} / ${_timeLabel(duration)}'
                : _timeLabel(target),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _failureLayer() {
    final message = _playback.message ?? context.l10n.local_playbackFailed;
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.78),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: Colors.white70, size: 40),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  children: [
                    OutlinedButton(
                      onPressed: () => unawaited(_reload()),
                      child: Text(context.l10n.local_play),
                    ),
                    if (_hasNext)
                      OutlinedButton(
                        onPressed: () => unawaited(_goTo(_i + 1)),
                        child: Text(context.l10n.local_episodes),
                      ),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: Text(MaterialLocalizations.of(context)
                          .closeButtonTooltip),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _timeLabel(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }
}
