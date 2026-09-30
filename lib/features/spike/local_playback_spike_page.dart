import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/theme/app_colors.dart';
import '../../core/platform/local_media_bridge.dart';
import '../../ui/ui.dart';

/// 路线 A 真机 spike:证明「SAF 选中的 content:// 文件,经 `/proc/self/fd/N`
/// 交给 libmpv 能播」。
///
/// 结论决定 M1 Android 走哪条路:
/// - 路线 A(本页验证):零拷贝,`openFd` 拿到 fd,把 `/proc/self/fd/N` 当输入路径。
/// - 路线 B(回退):`ContentResolver` 流式导入到应用私有目录,再播本地文件。
///
/// 只在 Android 上有意义;Windows 上打开会直接说明本页不适用。刻意**不复用**
/// `LocalPlayerPage`:这里要单独验证「fd 路径能不能开播」,掺进会话/进度逻辑反而看不清。
class LocalPlaybackSpikePage extends StatefulWidget {
  const LocalPlaybackSpikePage({super.key, this.bridge});

  /// 测试注入用;不传则自建(默认走平台判定)。
  final LocalMediaBridge? bridge;

  @override
  State<LocalPlaybackSpikePage> createState() => _LocalPlaybackSpikePageState();
}

class _LocalPlaybackSpikePageState extends State<LocalPlaybackSpikePage> {
  late final LocalMediaBridge _bridge = widget.bridge ?? LocalMediaBridge();

  final StringBuffer _logBuf = StringBuffer();
  PickedLocalLocation? _picked;
  List<LocalMediaEntry> _entries = const [];
  OpenedLocalFd? _fd;
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<String>? _errorSub;
  Duration _lastPosition = Duration.zero;
  bool _busy = false;
  String _status = '待开始';

  @override
  void initState() {
    super.initState();
    _line('=== 路线 A 验证(/proc/self/fd → libmpv) ===');
    _line('平台: ${Platform.operatingSystem} · 桥可用: ${_bridge.isAndroid}');
    if (!_bridge.isAndroid) {
      _line('本页只用于 Android 真机验证:Windows 直接播绝对路径,不经过 SAF。');
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _errorSub?.cancel();
    final fd = _fd;
    if (fd != null) unawaited(_releaseFdQuietly(fd.fd));
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  Future<void> _releaseFdQuietly(int fd) async {
    try {
      await _bridge.releaseFd(fd);
    } on Object {
      // 退出路径上的清理失败不值得打扰用户。
    }
  }

  void _line(String text) {
    _logBuf.writeln(text);
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } on Object catch (error) {
      _line('✗ 异常: $error');
      if (mounted) setState(() => _status = '失败:$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() => _run(() async {
        _line('\n=== ① 选目录(SAF) ===');
        final picked = await _bridge.pickDirectory();
        if (picked == null) {
          _line('用户取消。');
          return;
        }
        _picked = picked;
        _entries = const [];
        _line('名称: ${picked.name}');
        _line('URI: ${picked.uri}');
        _line('授权已持久化(takePersistableUriPermission);重启后应仍可读。');
        setState(() => _status = '已选目录:${picked.name}');
      });

  Future<void> _list() => _run(() async {
        final picked = _picked;
        if (picked == null) {
          _line('先选目录。');
          return;
        }
        _line('\n=== ② 列子项(桥内递归) ===');
        final entries = await _bridge.listChildren(picked.uri);
        _entries = entries;
        _line('共 ${entries.length} 个文件。');
        for (final entry in entries.take(10)) {
          _line('  ${entry.name} · ${entry.size} B · ${entry.mime}');
        }
        if (entries.length > 10) _line('  …(只列前 10 个)');
        setState(() => _status = '列到 ${entries.length} 个文件');
      });

  Future<void> _stat() => _run(() async {
        final entry = _firstVideo();
        if (entry == null) {
          _line('没有可用的文件,先选目录并列子项。');
          return;
        }
        _line('\n=== ③ stat ===');
        final info = await _bridge.stat(entry.uri);
        if (info == null) {
          _line('✗ stat 返回 null(文件被删或授权失效)。');
          return;
        }
        _line('name=${info.name} size=${info.size} '
            'mime=${info.mime} mtime=${info.lastModified}');
        setState(() => _status = 'stat 正常');
      });

  Future<void> _openFd() => _run(() async {
        final entry = _firstVideo();
        if (entry == null) {
          _line('没有可用的文件,先选目录并列子项。');
          return;
        }
        _line('\n=== ④ openFd ===');
        final opened = await _bridge.openFd(entry.uri);
        _fd = opened;
        _line('fd=${opened.fd} path=${opened.path}');
        // 先用 dart:io 直读前 16 字节:证明「本进程能通过 /proc/self/fd/N 读到内容」。
        // 只在 Android 上做:其它平台没有 /proc/self/fd,拿假 fd 去开文件只会白等。
        if (Platform.isAndroid) {
          try {
            final raf = await File(opened.path).open();
            final head = await raf.read(16);
            await raf.close();
            _line('Dart 直读前 16 字节: '
                '${head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
          } on Object catch (error) {
            _line('✗ Dart 直读失败: $error');
          }
        } else {
          _line('(非 Android,跳过 Dart 直读检查)');
        }
        setState(() => _status = 'fd=${opened.fd}');
      });

  /// [asFileUri] = true 时用 `file:///proc/self/fd/N`(项目里 buildLocalTrack 的形态),
  /// false 时用裸路径 —— 两种都试,mpv 对它们的处理可能不同。
  Future<void> _play({required bool asFileUri}) => _run(() async {
        final opened = _fd;
        if (opened == null) {
          _line('先执行 ④ openFd。');
          return;
        }
        final url = asFileUri ? Uri.file(opened.path).toString() : opened.path;
        _line('\n=== ⑤ 播放 ${asFileUri ? 'file:// 形态' : '裸路径形态'} ===');
        _line('输入: $url');

        final player = _player ??= Player(
          configuration: const PlayerConfiguration(
            // 本地文件不设大 buffer,也不传 protocolWhitelist(那是网络流用的)。
            logLevel: MPVLogLevel.error,
          ),
        );
        _controller ??= VideoController(player);
        _lastPosition = Duration.zero;
        await _positionSub?.cancel();
        _positionSub = player.stream.position.listen((position) {
          _lastPosition = position;
        });
        await _errorSub?.cancel();
        _errorSub = player.stream.error.listen((error) => _line('mpv error: $error'));

        try {
          await player.open(Media(url));
        } on Object catch (error) {
          _line('✗ open 抛异常: $error');
          return;
        }
        _line('open() 已返回,等 5 秒看 position 是否推进…');
        await Future<void>.delayed(const Duration(seconds: 5));
        final playing = await player.stream.playing.first
            .timeout(const Duration(seconds: 1), onTimeout: () => false);
        final position = _lastPosition;
        if (position > Duration.zero) {
          _line('✓ 路线 A 可用:position=${position.inMilliseconds}ms '
              '(playing=$playing)');
          _line('  结论:Android 用 openFd + /proc/self/fd/N 即可零拷贝播放。');
          if (mounted) setState(() => _status = '路线 A 可用');
        } else {
          _line('✗ position 没动(playing=$playing)。');
          _line('  先看上面有没有 mpv error;若报 could not open,'
              '则路线 A 不通 → 切路线 B(导入到应用私有目录)。');
          if (mounted) setState(() => _status = '路线 A 存疑');
        }
      });

  Future<void> _releaseFd() => _run(() async {
        final opened = _fd;
        if (opened == null) {
          _line('没有持有的 fd。');
          return;
        }
        _line('\n=== ⑥ 释放 fd ===');
        await _bridge.releaseFd(opened.fd);
        _fd = null;
        _line('已释放(幂等:重复调用不会报错)。');
        setState(() => _status = 'fd 已释放');
      });

  LocalMediaEntry? _firstVideo() {
    for (final entry in _entries) {
      if (entry.mime.startsWith('video/') || entry.name.contains('.')) {
        return entry;
      }
    }
    return _entries.isEmpty ? null : _entries.first;
  }

  void _copyLog() {
    Clipboard.setData(ClipboardData(text: _logBuf.toString()));
    showAppNotify(context, '日志已复制', kind: AppNotifyKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地播放 · 路线 A 验证'),
        actions: [
          IconButton(
            tooltip: '复制日志',
            onPressed: _copyLog,
            icon: const Icon(Icons.copy_all_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (controller != null)
            Container(
              height: 200,
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.line),
                color: Colors.black,
              ),
              clipBehavior: Clip.antiAlias,
              child: Video(
                controller: controller,
                controls: NoVideoControls as VideoControlsBuilder?,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _pick,
                  child: const Text('① 选目录'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _list,
                  child: const Text('② 列子项'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _stat,
                  child: const Text('③ stat'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _openFd,
                  child: const Text('④ openFd'),
                ),
                FilledButton(
                  onPressed: _busy ? null : () => _play(asFileUri: false),
                  child: const Text('⑤ 播裸路径'),
                ),
                FilledButton(
                  onPressed: _busy ? null : () => _play(asFileUri: true),
                  child: const Text('⑤ 播 file://'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _releaseFd,
                  child: const Text('⑥ 释放 fd'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _status,
                    style: TextStyle(
                        color: p.textMuted, fontSize: 11.5, height: 1.4),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Container(
              width: double.infinity,
              color: p.surface,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  _logBuf.isEmpty ? '日志会显示在这里。' : _logBuf.toString(),
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 11.5,
                    height: 1.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
