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

  // 诊断:流订阅 + 采样定时器 + 卡顿计数。
  final List<StreamSubscription<dynamic>> _diag = [];
  Timer? _diagTimer;
  int _stalls = 0;

  @override
  void initState() {
    super.initState();
    _startDiag(); // 先订阅,别漏掉 open 早期事件
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
    // DASH(如 B站高清):音视频分离,视频轨无声,需把音频流当**外挂音轨**挂上。
    // 必须在 open(loadfile)**之后**用 `audio-add`(setAudioTrack→audio-add 命令,
    // 参数是字面量 argv,不会被拆);切勿用 `audio-files` 属性——它是 path-list,
    // Android/Linux 下按 `:` 分隔符会把 `https://` URL 切碎导致挂载失败(静音)。
    // 新的 open() 会 loadfile 重置,上一集/上一清晰度的外挂音轨自动失效,无需手动清理。
    final au = t.audioUrl;
    if (au != null && au.isNotEmpty) {
      try {
        await _player.setAudioTrack(AudioTrack.uri(au));
        _av('外挂音轨已挂载(DASH)');
      } catch (e) {
        _av('!! 外挂音轨挂载失败: $e');
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _go(int delta) {
    final n = _i + delta;
    if (n < 0 || n >= widget.episodes.length) return;
    setState(() => _i = n);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hasPrev = _i > 0;
    final hasNext = _i < widget.episodes.length - 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${widget.animeTitle} · ${_ep.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        actions: [
          if (_tracks.length > 1)
            PopupMenuButton<VideoTrack>(
              tooltip: '线路 / 清晰度',
              icon: const Icon(Icons.hd_rounded),
              onSelected: (t) async {
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
              },
              itemBuilder: (_) => [
                for (final t in _tracks)
                  PopupMenuItem(
                    value: t,
                    child: Text(
                      (t.quality.isEmpty ? '线路' : t.quality) +
                          (identical(t, _current) ? '  ✓' : ''),
                    ),
                  ),
              ],
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
                  : Video(controller: _controller),
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
}
