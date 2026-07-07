import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' hide VideoTrack; // 用本项目的 VideoTrack
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/source/models.dart';
import '../../core/source/source.dart';
import '../../core/source/source_registry.dart';
import '../../app/theme/app_colors.dart';

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
  late final Player _player = Player(
    configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
  );
  late final VideoController _controller = VideoController(_player);
  late final MangaSource _source = buildSource(widget.meta);

  late int _i = widget.index;
  List<VideoTrack> _tracks = const [];
  VideoTrack? _current;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 关键:_tuneBuffering 不能 gate 住 _load —— setProperty 内部会
    // `await videoControllerCompleter`,而该 completer 要等 open() 后 VO 就绪才完成;
    // 若先 await 调优再 open,就成了「调优等 VO、VO 等 open、open 等调优」的死锁 → 永远不播。
    // 故两者并发:_load 立刻开播,调优在 VO 就绪后自然生效(mpv 支持运行时改预读)。
    _tuneBuffering();
    _load();
  }

  /// 番剧源的 m3u8 分片常仅 2~6 秒/片;libmpv 默认 `demuxer-readahead-secs` 只有 ~1s,
  /// 于是「播一片 → 等下一片」= 每几秒卡一下。这里放大预读 + 缓存,让它一次预抓多片、
  /// 平滑网络抖动。Win/Android 同为 libmpv 后端,通用。**绝不抛/绝不阻塞播放**。
  Future<void> _tuneBuffering() async {
    try {
      final p = _player.platform;
      if (p is! NativePlayer) return;
      Future<void> set(String k, String v) async {
        try {
          await p.setProperty(k, v);
        } catch (_) {}
      }

      await set('cache', 'yes');
      await set('cache-secs', '60'); // 缓存已解复用的 60s
      await set('demuxer-readahead-secs', '30'); // 向前预读 30s(≈5~15 片)
      await set('demuxer-max-bytes', '${64 * 1024 * 1024}');
      await set('demuxer-max-back-bytes', '${32 * 1024 * 1024}');
      // 网络抖动/分片瞬断时自动重连,别直接判死。
      await set('stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
    } catch (_) {}
  }

  @override
  void dispose() {
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
      final tracks = await _source.getVideo(widget.animeId, _ep.id);
      if (!mounted) return;
      if (tracks.isEmpty) {
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
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _play(VideoTrack t) async {
    _current = t;
    await _player.open(Media(t.url, httpHeaders: t.headers));
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
              onSelected: (t) {
                setState(() => _loading = true);
                _play(t);
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

  Widget _errorView(AppPalette p) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 40, color: Colors.white54),
              const SizedBox(height: 12),
              Text('播放失败',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SelectableText(_error ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 14),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
}
