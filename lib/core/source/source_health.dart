import 'source.dart';
import '../novel/novel_source.dart';
import '../script/js_engine.dart';
import 'source_registry.dart';

typedef MangaHealthSourceBuilder = MangaSource Function(SourceMeta);
typedef NovelHealthSourceBuilder = NovelSource Function(SourceMeta);

class _HealthSummary {
  const _HealthSummary({
    required this.count,
    required this.sample,
    required this.withCover,
  });

  final int count;
  final String sample;
  final int withCover;
}

_HealthSummary _summarizeHealthItems<T>(
  List<T> items, {
  required String Function(T) titleOf,
  required String? Function(T) coverOf,
}) =>
    _HealthSummary(
      count: items.length,
      sample: items.take(5).map(titleOf).join('、'),
      withCover: items.where((item) => (coverOf(item) ?? '').isNotEmpty).length,
    );

/// 源可用性状态。
enum SourceHealthStatus {
  unknown, // 未检测
  checking, // 检测中
  ok, // 正常(发现返回 ≥1 部)
  empty, // 可达但返回 0 部(疑似限流 / 解析失效)
  fail, // 失败(网络 / 解析异常)
}

/// 检测失败的原因分类。核心层只给码,文案由 UI 层按 l10n 映射。
enum SourceHealthFailure {
  /// 脚本同步执行吃满了预算(死循环 / 退化正则),引擎已被熔断。
  /// 这类失败**不是网络问题**,重试也没用,得换/修脚本。
  scriptStuck,

  /// 其它:网络、解析、契约不符…
  other,
}

/// 一次可用性检测的结果:状态 + 供弹窗展示的日志。
class SourceHealthResult {
  const SourceHealthResult(this.status, this.log,
      {this.elapsedMs = 0, this.count, this.failure});

  final SourceHealthStatus status;
  final String log;
  final int elapsedMs;
  final int? count; // 发现到的条目数(成功时)

  /// 仅在 [status] 为 fail 时有值。
  final SourceHealthFailure? failure;

  static const unknown = SourceHealthResult(SourceHealthStatus.unknown, '未检测');
  static const checking =
      SourceHealthResult(SourceHealthStatus.checking, '检测中…（联网）');
}

/// 联网检测一个源的可用性:按内容类型构建源 → 跑发现接口(带超时)→ 归纳状态 + 生成日志。
/// 纯诊断,不改任何状态;检测结束会释放源(JS 引擎)。
///
/// 注意 [timeout] 只管得住**异步**部分(网络):脚本的同步求值一旦跑起来就没人能打断它,
/// 那条线由 [JsEngine] 自己的执行预算兜底(超预算抛 [JsExecutionOverrun],
/// 在这里归为 [SourceHealthFailure.scriptStuck])。
Future<SourceHealthResult> checkSourceHealth(
  SourceMeta meta, {
  Duration timeout = const Duration(seconds: 25),
  MangaHealthSourceBuilder mangaBuilder = buildSource,
  NovelHealthSourceBuilder novelBuilder = buildNovelSource,
}) async {
  final sw = Stopwatch()..start();
  final discoveryName = meta.isManga || meta.isAnime
      ? 'getDiscovery'
      : meta.isNovel
          ? 'getNovelDiscovery'
          : null;
  final b = StringBuffer()
    ..writeln('源:${meta.name}  (id: ${meta.id})')
    ..writeln('传输:${meta.useWebView ? 'WebView' : 'dio'}'
        '${meta.experimental ? ' · 实验性' : ''}');
  if (discoveryName != null) {
    b.writeln('测试:$discoveryName(1)  超时 ${timeout.inSeconds}s');
  }
  b.writeln('──────────');
  void Function()? dispose;
  try {
    late final _HealthSummary summary;
    if (meta.isManga || meta.isAnime) {
      final src = mangaBuilder(meta);
      dispose = src.dispose;
      final page = await src.getDiscovery(1).timeout(timeout);
      summary = _summarizeHealthItems(
        page.items,
        titleOf: (item) => item.title,
        coverOf: (item) => item.cover,
      );
    } else if (meta.isNovel) {
      final src = novelBuilder(meta);
      dispose = src.dispose;
      final page = await src.getNovelDiscovery(1).timeout(timeout);
      summary = _summarizeHealthItems(
        page.items,
        titleOf: (item) => item.title,
        coverOf: (item) => item.cover,
      );
    } else {
      throw ArgumentError.value(
        meta.kind,
        'meta.kind',
        'expected manga, anime, or novel',
      );
    }
    sw.stop();
    b.writeln('耗时:${sw.elapsedMilliseconds} ms');
    if (summary.count > 0) {
      b
        ..writeln('结果:✓ 发现 ${summary.count} 部(其中 ${summary.withCover} 部带封面)')
        ..writeln('示例:${summary.sample}');
      return SourceHealthResult(SourceHealthStatus.ok, b.toString().trimRight(),
          elapsedMs: sw.elapsedMilliseconds, count: summary.count);
    }
    b
      ..writeln('结果:⚠ 发现 0 部')
      ..writeln('可能:被限流 / 需登录 / 站点结构变动导致解析为空。');
    return SourceHealthResult(
        SourceHealthStatus.empty, b.toString().trimRight(),
        elapsedMs: sw.elapsedMilliseconds, count: 0);
  } catch (e) {
    sw.stop();
    // 脚本把 isolate 占满了预算(死循环 / 退化正则):不是网络问题,单独归一类,
    // 让 UI 说清楚「换/修脚本」而不是让用户一遍遍重试。
    final stuck = e is JsExecutionOverrun;
    b
      ..writeln('耗时:${sw.elapsedMilliseconds} ms')
      ..writeln('结果:✗ 失败')
      ..writeln('$e');
    return SourceHealthResult(
      SourceHealthStatus.fail,
      b.toString().trimRight(),
      elapsedMs: sw.elapsedMilliseconds,
      failure:
          stuck ? SourceHealthFailure.scriptStuck : SourceHealthFailure.other,
    );
  } finally {
    dispose?.call();
  }
}
