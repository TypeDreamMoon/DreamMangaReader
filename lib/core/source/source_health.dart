import 'package:meta/meta.dart';

import 'source.dart';
import '../novel/novel_source.dart';
import '../script/js_engine.dart';
import 'source_registry.dart';

typedef MangaHealthSourceBuilder = MangaSource Function(SourceMeta);
typedef NovelHealthSourceBuilder = NovelSource Function(SourceMeta);

class _HealthSummary {
  const _HealthSummary({
    required this.count,
    required this.samples,
    required this.withCover,
  });

  final int count;
  final List<String> samples;
  final int withCover;
}

_HealthSummary _summarizeHealthItems<T>(
  List<T> items, {
  required String Function(T) titleOf,
  required String? Function(T) coverOf,
}) =>
    _HealthSummary(
      count: items.length,
      samples: items.take(5).map(titleOf).toList(),
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

/// 源的传输方式(检测日志里要说清楚走的哪条路)。
enum SourceTransport { dio, webView }

/// 一次检测的**事实**:谁、怎么测的、结果如何。
///
/// 这里刻意不含任何成句的文案——源管理页拿它按当前语言渲染检测日志
/// (以前核心层直接拼中文,英/日界面照样弹一整屏中文)。
@immutable
class SourceHealthReport {
  const SourceHealthReport({
    required this.sourceName,
    required this.sourceId,
    required this.transport,
    required this.experimental,
    required this.timeoutSeconds,
    this.discoveryFn,
    this.elapsedMs = 0,
    this.count,
    this.withCover = 0,
    this.samples = const [],
    this.errorDetail,
  });

  final String sourceName;
  final String sourceId;
  final SourceTransport transport;
  final bool experimental;
  final int timeoutSeconds;

  /// 被调用的发现接口名(未知内容类型时为 null)。
  final String? discoveryFn;

  final int elapsedMs;

  /// 发现到的条目数(还没跑到结果时为 null)。
  final int? count;

  /// 其中带封面的条目数。
  final int withCover;

  /// 前几条的标题,给人肉眼确认解析对不对。
  final List<String> samples;

  /// 失败时的底层原因(异常 toString);成功时为 null。
  final String? errorDetail;

  SourceHealthReport copyWith({
    int? elapsedMs,
    int? count,
    int? withCover,
    List<String>? samples,
    String? errorDetail,
  }) =>
      SourceHealthReport(
        sourceName: sourceName,
        sourceId: sourceId,
        transport: transport,
        experimental: experimental,
        timeoutSeconds: timeoutSeconds,
        discoveryFn: discoveryFn,
        elapsedMs: elapsedMs ?? this.elapsedMs,
        count: count ?? this.count,
        withCover: withCover ?? this.withCover,
        samples: samples ?? this.samples,
        errorDetail: errorDetail ?? this.errorDetail,
      );
}

/// 一次可用性检测的结果:状态 + 供弹窗渲染的结构化报告。
@immutable
class SourceHealthResult {
  const SourceHealthResult(
    this.status, {
    this.report,
    this.elapsedMs = 0,
    this.count,
    this.failure,
  });

  final SourceHealthStatus status;

  /// 检测事实(unknown / checking 时为 null——还没测过,没什么可报告的)。
  final SourceHealthReport? report;

  final int elapsedMs;
  final int? count; // 发现到的条目数(成功时)

  /// 仅在 [status] 为 fail 时有值。
  final SourceHealthFailure? failure;

  static const unknown = SourceHealthResult(SourceHealthStatus.unknown);
  static const checking = SourceHealthResult(SourceHealthStatus.checking);
}

/// 联网检测一个源的可用性:按内容类型构建源 → 跑发现接口(带超时)→ 归纳状态 + 结构化报告。
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
  final base = SourceHealthReport(
    sourceName: meta.name,
    sourceId: meta.id,
    transport:
        meta.useWebView ? SourceTransport.webView : SourceTransport.dio,
    experimental: meta.experimental,
    timeoutSeconds: timeout.inSeconds,
    discoveryFn: discoveryName,
  );
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
    final report = base.copyWith(
      elapsedMs: sw.elapsedMilliseconds,
      count: summary.count,
      withCover: summary.withCover,
      samples: summary.samples,
    );
    return SourceHealthResult(
      summary.count > 0 ? SourceHealthStatus.ok : SourceHealthStatus.empty,
      report: report,
      elapsedMs: sw.elapsedMilliseconds,
      count: summary.count,
    );
  } catch (e) {
    sw.stop();
    // 脚本把 isolate 占满了预算(死循环 / 退化正则):不是网络问题,单独归一类,
    // 让 UI 说清楚「换/修脚本」而不是让用户一遍遍重试。
    final stuck = e is JsExecutionOverrun;
    return SourceHealthResult(
      SourceHealthStatus.fail,
      report: base.copyWith(
        elapsedMs: sw.elapsedMilliseconds,
        errorDetail: '$e',
      ),
      elapsedMs: sw.elapsedMilliseconds,
      failure:
          stuck ? SourceHealthFailure.scriptStuck : SourceHealthFailure.other,
    );
  } finally {
    dispose?.call();
  }
}
