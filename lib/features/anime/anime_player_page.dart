import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack; // 用本项目的 VideoTrack
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/net/app_proxy.dart';
import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../app/theme/app_colors.dart';
import '../../ui/ui.dart';

/// 播放诊断开关。开着时播放全程往控制台打 `[AV]` 日志(开播/取流/卡顿/位置/mpv 报错)。
/// 平时关闭(避免刷屏);排查番剧播放问题时置 true 复现即可。
const bool kAvDiag = false;
void _av(String m) {
  if (kAvDiag) debugPrint('[AV] $m');
}

/// 番剧 CDN 大多会对 mpv 默认 UA(`Lavf/…`)直接**重置连接**(curl 带浏览器 UA 却 200)。
/// 播放前必须把 mpv 的 `user-agent` 选项换成浏览器 UA,否则很多源根本打不开。
const String _kBrowserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

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
  });

  final SourceMeta meta;
  final String animeId;
  final String animeTitle;
  final List<Chapter> episodes; // 番剧沿用章节契约:一集=一个 Chapter
  final int index;

  @override
  State<AnimePlayerPage> createState() => _AnimePlayerPageState();
}

class _AnimePlayerPageState extends State<AnimePlayerPage> {
  // 更大的前向缓冲(默认桌面 32MB);HLS 每片才 2s,大缓冲能一次装下更多片。
  // 诊断期把 mpv 日志级别拉到 warn,能看到 404/TLS/解码 等硬错误。
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      bufferSize: 64 * 1024 * 1024,
      logLevel: kAvDiag ? MPVLogLevel.warn : MPVLogLevel.error,
    ),
  );
  late final VideoController _controller = VideoController(_player);
  late final MangaSource _source = buildSource(widget.meta);

  late int _i = widget.index;
  List<VideoTrack> _tracks = const [];
  VideoTrack? _current;
  bool _loading = true;
  String? _error;

  // DASH 外挂音轨(B站):记住待挂载的音频 URL,在**首帧开播后**(demuxer 就绪)才挂,
  // 而非 open() 一返回就挂 —— 冷启时主流 demuxer 还没建好,过早的 audio-add 会被静默丢弃
  // (表现为「第一次进没声音」)。以 playing 首次 true 作为「主流已就绪」的信号。
  String? _pendingAudioUrl;
  bool _audioAttached = false;

  // 悬浮控制面板(右侧抽屉):选集 / 线路 / 设置。
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _panelTab = 0; // 0=选集 1=线路 2=设置
  double _rate = 1.0; // 倍速(跨集保持)
  BoxFit _fit = BoxFit.contain; // 画面填充

  // 诊断:流订阅 + 采样定时器 + 卡顿计数。
  final List<StreamSubscription<dynamic>> _diag = [];
  Timer? _diagTimer;
  int _stalls = 0;

  @override
  void initState() {
    super.initState();
    _startDiag(); // 先订阅,别漏掉 open 早期事件
    // DASH 外挂音轨挂载(非诊断态也要):tracks 事件 = mpv 已探明当前文件的音视频流 =
    // 主流 demuxer 就绪,此刻 audio-add 才生效(冷启时 open() 一返回就挂会被丢弃 → 没声音)。
    // 每次 open() 重新探流都会再发一次 tracks 事件,故换集/换清晰度都会触发重挂;幂等。
    _diag.add(_player.stream.tracks.listen((_) => _attachPendingAudio()));
    // 关键:_tuneBuffering 不能 gate 住 _load —— setProperty 内部会
    // `await videoControllerCompleter`,而该 completer 要等 open() 后 VO 就绪才完成;
    // 若先 await 调优再 open,就成了「调优等 VO、VO 等 open、open 等调优」的死锁 → 永远不播。
    // 故两者并发:_load 立刻开播,调优在 VO 就绪后自然生效(mpv 支持运行时改预读)。
    _tuneBuffering();
    _load();
  }

  /// 订阅播放状态流 + 每 2s 采样,把播放全程打成 `[AV]` 时间线。定位卡顿用。
  void _startDiag() {
    if (!kAvDiag) return;
    _av('源=${widget.meta.id} 番=${widget.animeId} 集数=${widget.episodes.length} 起始=${widget.index}');
    _diag.add(_player.stream.playing.listen(
        (v) => _av('playing=$v  pos=${_player.state.position.inSeconds}s')));
    _diag.add(_player.stream.buffering.listen((v) {
      if (v) _stalls++;
      _av('buffering=$v${v ? " (第$_stalls次卡)" : ""}  '
          'pos=${_player.state.position.inSeconds}s buf=${_player.state.buffer.inSeconds}s');
    }));
    _diag.add(_player.stream.completed.listen((v) {
      if (v) _av('completed (放完)');
    }));
    _diag.add(_player.stream.error.listen((e) => _av('!! ERROR: $e')));
    _diag.add(_player.stream.log.listen((e) => _av('mpv[${e.level}] ${e.prefix}: ${e.text.trim()}')));
    _diagTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final s = _player.state;
      _av('采样 pos=${s.position.inSeconds}s buf=${s.buffer.inSeconds}s '
          'playing=${s.playing} buffering=${s.buffering} 累计卡=$_stalls');
    });
  }

  /// 番剧源的 m3u8 分片常仅 2~6 秒/片;libmpv 默认 `demuxer-readahead-secs` 只有 ~1s,
  /// 于是「播一片 → 等下一片」= 每几秒卡一下。这里**只**放大内存里的向前预读 —— 安全。
  ///
  /// ⚠️ 血泪教训:别设 `cache=yes`(会让 mpv 尝试建**文件缓存**,失败后 completed 误触发、
  /// 位置重置回 0 → 「播 2 秒又重来」的循环);也别设 `stream-lavf-o`(和环境代理冲突,
  /// 触发 `httpproxy` 协议不在白名单)。predemux 预读是纯内存,不碰这些坑。
  Future<void> _tuneBuffering() async {
    try {
      final p = _player.platform;
      if (p is! NativePlayer) return;
      Future<void> set(String k, String v) async {
        try {
          await p.setProperty(k, v);
        } catch (_) {}
      }

      await set('demuxer-readahead-secs', '20'); // 向前预读 20s(内存,≈3~10 片)
      await set('demuxer-max-bytes', '${64 * 1024 * 1024}');
    } catch (_) {}
  }

  /// open() 前配置 mpv 网络:浏览器 UA + 走 App 代理。用 `waitForPlayerInitialization`
  /// 只等 mpv 句柄就绪、**不等 VideoController**(避免死锁);setProperty 传 false 同理。
  Future<void> _applyNetOptions() async {
    try {
      final p = _player.platform;
      if (p is! NativePlayer) return;
      await p.waitForPlayerInitialization;
      // UA:见 [_kBrowserUa]。
      final ua = _current?.headers?['User-Agent'] ??
          _current?.headers?['user-agent'] ??
          _kBrowserUa;
      await p.setProperty('user-agent', ua, waitForInitialization: false);
      // 视频跟随 App 代理(和 dio 一致)。直连某些 CDN 会因地区/指纹被 TLS 重置;
      // 走代理(如 FlClash)按其规则出口即可正常握手。没配代理则直连。
      final proxy = AppProxy.current;
      if (proxy != null && proxy.isNotEmpty) {
        await p.setProperty('http-proxy', 'http://$proxy',
            waitForInitialization: false);
        // 用 HTTP 代理隧道 HTTPS 时,ffmpeg 需把 `httpproxy` 协议加进白名单,否则
        // 「Protocol 'httpproxy' not on whitelist」→ 打不开。stream + demuxer 两层都要设。
        // 注意:值里有逗号,mpv 必须用方括号包住,否则被当成多个 key=value → 解析报错。
        const wl =
            'protocol_whitelist=[file,crypto,data,http,https,tcp,tls,httpproxy,hls,applehttp]';
        await p.setProperty('stream-lavf-o', wl, waitForInitialization: false);
        await p.setProperty('demuxer-lavf-o', wl, waitForInitialization: false);
        _av('mpv 走代理 $proxy');
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _diagTimer?.cancel();
    for (final s in _diag) {
      s.cancel();
    }
    _player.dispose();
    _source.dispose();
    super.dispose();
  }

  Chapter get _ep => widget.episodes[_i];

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _av('getVideo 开始 集=${_ep.name} epId=${_ep.id}');
      final sw = Stopwatch()..start();
      final tracks = await _source.getVideo(widget.animeId, _ep.id);
      _av('getVideo 返回 用时${sw.elapsedMilliseconds}ms → ${tracks.length}轨: '
          '${tracks.map((t) => "${t.quality.isEmpty ? "?" : t.quality}${t.hls ? "/hls" : ""}").join(", ")}');
      if (!mounted) return;
      if (tracks.isEmpty) {
        _av('!! 没有可播放线路');
        setState(() {
          _loading = false;
          _error = '没有解析到可播放的线路';
        });
        return;
      }
      // 优先 HLS(自适应),否则第一条。
      final pick = tracks.firstWhere((t) => t.hls, orElse: () => tracks.first);
      _tracks = tracks;
      await _play(pick);
    } catch (e) {
      _av('!! _load 抛错: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _play(VideoTrack t) async {
    _current = t;
    // 待挂载音轨随本次播放复位;非 DASH(audioUrl 空)则清空,new open() 会重置轨道无残留。
    _audioAttached = false;
    _pendingAudioUrl =
        (t.audioUrl != null && t.audioUrl!.isNotEmpty) ? t.audioUrl : null;
    await _applyNetOptions(); // 关键:open 前配 mpv UA + 代理,否则 CDN 重置连接
    _av('open url=${t.url}');
    _av('    headers=${t.headers ?? "(无)"} ua=浏览器');
    final sw = Stopwatch()..start();
    try {
      await _player.open(Media(t.url, httpHeaders: t.headers));
      _av('open() 返回 用时${sw.elapsedMilliseconds}ms');
    } catch (e) {
      _av('!! open 抛错 用时${sw.elapsedMilliseconds}ms: $e');
      rethrow;
    }
    // DASH 外挂音轨不在这里挂 —— 见 _attachPendingAudio(在首帧开播后挂,避开冷启竞态)。
    // 倍速跨集保持:新 loadfile 后重设一次(mpv speed 虽是全局,但保险起见显式回填)。
    if (_rate != 1.0) {
      try {
        await _player.setRate(_rate);
      } catch (_) {}
    }
    if (mounted) setState(() => _loading = false);
  }

  void _go(int delta) => _goTo(_i + delta);

  /// 跳到第 [index] 集(绝对)。越界/同集则忽略;换集后关面板。
  void _goTo(int index) {
    if (index < 0 || index >= widget.episodes.length) return;
    _scaffoldKey.currentState?.closeEndDrawer();
    if (index == _i) return;
    setState(() => _i = index);
    _load();
  }

  /// 切线路 / 清晰度(与 _play 同逻辑,含错误兜底)。切完关面板。
  Future<void> _switchTrack(VideoTrack t) async {
    _scaffoldKey.currentState?.closeEndDrawer();
    if (identical(t, _current)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _play(t);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _setRate(double r) async {
    setState(() => _rate = r);
    try {
      await _player.setRate(r);
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

  /// 把 [_pendingAudioUrl] 作为外挂音轨挂到当前已开播的文件上。用 `audio-add`
  /// (setAudioTrack→audio-add 命令,字面量 argv 不会被路径分隔符拆),**不用** `audio-files`
  /// 属性(path-list,Android 按 `:` 会切碎 https URL)。playing 首次 true 后调用,确保
  /// 主流 demuxer 已就绪、audio-add 不被丢弃。幂等:每次播放只挂一次。
  Future<void> _attachPendingAudio() async {
    final au = _pendingAudioUrl;
    if (au == null || au.isEmpty || _audioAttached) return;
    _audioAttached = true; // 先占位防重入;失败再回滚,等下个 playing 事件重试
    try {
      await _player.setAudioTrack(AudioTrack.uri(au));
      _av('外挂音轨已挂载(DASH)');
    } catch (e) {
      _audioAttached = false;
      _av('!! 外挂音轨挂载失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasPrev = _i > 0;
    final hasNext = _i < widget.episodes.length - 1;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      endDrawer: _controlPanel(p),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${widget.animeTitle} · ${_ep.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        actions: [
          if (_current != null && _current!.quality.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(_current!.quality,
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          IconButton(
            tooltip: '选集 / 线路 / 设置',
            icon: const Icon(Icons.playlist_play_rounded),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              child: _error != null
                  ? _errorView(p)
                  : Video(controller: _controller, fit: _fit),
            ),
          ),
          // 集导航条
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: hasPrev ? () => _go(-1) : null,
                  icon: const Icon(Icons.skip_previous_rounded),
                  label: const Text('上一集'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white54)),
                const Spacer(),
                TextButton.icon(
                  onPressed: hasNext ? () => _go(1) : null,
                  icon: const Icon(Icons.skip_next_rounded),
                  label: const Text('下一集'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorView(AppPalette p) => AppErrorView(
        onDark: true,
        icon: Icons.error_outline_rounded,
        title: '播放失败',
        message: _error ?? '',
        onRetry: _load,
        retryLabel: '重试',
      );

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
        final on = identical(t, _current);
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

class _PanelLabel extends StatelessWidget {
  const _PanelLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: Colors.white,
          fontSize: 14.5,
          fontWeight: FontWeight.w700));
}
