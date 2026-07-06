import 'source.dart';
import 'source_registry.dart';

/// 源可用性状态。
enum SourceHealthStatus {
  unknown, // 未检测
  checking, // 检测中
  ok, // 正常(发现返回 ≥1 部)
  empty, // 可达但返回 0 部(疑似限流 / 解析失效)
  fail, // 失败(网络 / 解析异常)
}

/// 一次可用性检测的结果:状态 + 供弹窗展示的日志。
class SourceHealthResult {
  const SourceHealthResult(this.status, this.log, {this.elapsedMs = 0, this.count});

  final SourceHealthStatus status;
  final String log;
  final int elapsedMs;
  final int? count; // 发现到的条目数(成功时)

  static const unknown = SourceHealthResult(SourceHealthStatus.unknown, '未检测');
  static const checking = SourceHealthResult(SourceHealthStatus.checking, '检测中…（联网）');
}

/// 联网检测一个源的可用性:构建源 → 跑 `getDiscovery(1)`(带超时)→ 归纳状态 + 生成日志。
/// 纯诊断,不改任何状态;检测结束会释放源(JS 引擎)。
Future<SourceHealthResult> checkSourceHealth(
  SourceMeta meta, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final sw = Stopwatch()..start();
  final b = StringBuffer()
    ..writeln('源:${meta.name}  (id: ${meta.id})')
    ..writeln('传输:${meta.useWebView ? 'WebView' : 'dio'}'
        '${meta.experimental ? ' · 实验性' : ''}')
    ..writeln('测试:getDiscovery(1)  超时 ${timeout.inSeconds}s')
    ..writeln('──────────');
  MangaSource? src;
  try {
    src = buildSource(meta);
    final page = await src.getDiscovery(1).timeout(timeout);
    sw.stop();
    final n = page.items.length;
    b.writeln('耗时:${sw.elapsedMilliseconds} ms');
    if (n > 0) {
      final sample = page.items.take(5).map((m) => m.title).join('、');
      final withCover = page.items.where((m) => (m.cover ?? '').isNotEmpty).length;
      b
        ..writeln('结果:✓ 发现 $n 部(其中 $withCover 部带封面)')
        ..writeln('示例:$sample');
      return SourceHealthResult(SourceHealthStatus.ok, b.toString().trimRight(),
          elapsedMs: sw.elapsedMilliseconds, count: n);
    }
    b
      ..writeln('结果:⚠ 发现 0 部')
      ..writeln('可能:被限流 / 需登录 / 站点结构变动导致解析为空。');
    return SourceHealthResult(SourceHealthStatus.empty, b.toString().trimRight(),
        elapsedMs: sw.elapsedMilliseconds, count: 0);
  } catch (e) {
    sw.stop();
    b
      ..writeln('耗时:${sw.elapsedMilliseconds} ms')
      ..writeln('结果:✗ 失败')
      ..writeln('$e');
    return SourceHealthResult(SourceHealthStatus.fail, b.toString().trimRight(),
        elapsedMs: sw.elapsedMilliseconds);
  } finally {
    src?.dispose();
  }
}
