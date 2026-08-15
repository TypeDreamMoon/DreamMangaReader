import 'package:flutter/foundation.dart';

import '../log/app_log.dart';
import '../source/source.dart';
import '../source/source_registry.dart';
import 'update_tracker.dart';

/// 一本待检查的收藏。[shelfKey] 是账本的键(与 `ShelfItem.key` 同口径)。
@immutable
class UpdateTarget {
  const UpdateTarget({
    required this.shelfKey,
    required this.sourceId,
    required this.itemId,
    required this.title,
  });

  final String shelfKey;
  final String sourceId;
  final String itemId;
  final String title;
}

/// 一次全量扫描的结果。
@immutable
class UpdateSweepResult {
  const UpdateSweepResult({
    required this.checked,
    required this.failed,
    required this.updatedWorks,
    required this.newChapters,
  });

  /// 成功查到话数的本数。
  final int checked;

  /// 源报错 / 脚本损坏 / 超时而跳过的本数。
  final int failed;

  /// 有新话的本数。
  final int updatedWorks;

  /// 新话总数(跨所有书累加)。
  final int newChapters;

  bool get hasUpdates => updatedWorks > 0;
}

/// 查一本书当前有多少话。返回 null = 这次没查到(源出错),**不要**当成 0 话,
/// 那会把账本基线压坏。
typedef ChapterCountFetcher = Future<int?> Function(UpdateTarget target);

/// 追更扫描:遍历书架收藏,查每本现在有多少话,把结果交给 [LibraryUpdateTracker]。
///
/// 联网那半单独放这里,并且把「怎么查话数」抽成 [ChapterCountFetcher] 注入 ——
/// 测试就能不碰网络地验证并发、容错和计数,而账本那半本来就是纯逻辑。
class LibraryUpdateChecker {
  LibraryUpdateChecker({
    required this.tracker,
    ChapterCountFetcher? fetcher,
    this.concurrency = 3,
  }) : _fetch = fetcher ?? fetchChapterCount;

  final LibraryUpdateTracker tracker;
  final ChapterCountFetcher _fetch;

  /// 同时查几本。源站多半经不起并发轰炸,默认 3 是「比串行快得多、又不像爬虫」
  /// 的折中;真正的限速仍由各源脚本自己负责。
  final int concurrency;

  bool _running = false;
  bool get running => _running;

  /// 扫描 [targets]。同一时刻只允许一次扫描(重复调用直接返回空结果)。
  ///
  /// [now] 由调用方给,便于测试;[onProgress] 用于驱动进度条(已完成数 / 总数)。
  Future<UpdateSweepResult> sweep(
    List<UpdateTarget> targets, {
    required int now,
    void Function(int done, int total)? onProgress,
  }) async {
    if (_running || targets.isEmpty) {
      return const UpdateSweepResult(
          checked: 0, failed: 0, updatedWorks: 0, newChapters: 0);
    }
    _running = true;
    var checked = 0;
    var failed = 0;
    var updatedWorks = 0;
    var newChapters = 0;
    var done = 0;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= targets.length) return;
        final t = targets[i];
        try {
          final count = await _fetch(t);
          if (count == null) {
            failed++;
          } else {
            checked++;
            final gained = tracker.recordCheck(t.shelfKey, count, now: now);
            if (gained > 0) {
              updatedWorks++;
              newChapters += gained;
              AppLog.i.success(
                  LogCat.update, '《${t.title}》新增 $gained 话(共 $count 话)');
            }
          }
        } catch (e) {
          // 一本查不动不该中断整轮 —— 死源、坏脚本、超时都归到 failed。
          failed++;
          AppLog.i.warn(LogCat.update, '检查《${t.title}》失败',
              detail: '${t.sourceId} · $e');
        } finally {
          onProgress?.call(++done, targets.length);
        }
      }
    }

    try {
      final lanes = concurrency < 1 ? 1 : concurrency;
      await Future.wait([
        for (var i = 0; i < lanes && i < targets.length; i++) worker(),
      ]);
      tracker.retainOnly({for (final t in targets) t.shelfKey});
      tracker.recordSweep(now);
    } finally {
      _running = false;
    }

    AppLog.i.info(
        LogCat.update,
        '追更检查完成 · $checked 本已查'
        '${failed > 0 ? ' · $failed 本失败' : ''}'
        '${updatedWorks > 0 ? ' · $updatedWorks 本有更新' : ' · 无更新'}');

    return UpdateSweepResult(
      checked: checked,
      failed: failed,
      updatedWorks: updatedWorks,
      newChapters: newChapters,
    );
  }
}

/// 单页最多翻这么多次。绝大多数源一页就把目录给全了(`hasNext == false`),
/// 这个上限只是防某个源的 hasNext 永远为 true 时把扫描卡死在一本书上。
const _maxChapterPages = 30;

/// 默认实现:建源 → 走完目录分页 → 数话数。源用完必须 dispose。
Future<int?> fetchChapterCount(UpdateTarget target) async {
  final meta = sourceMetaById(target.sourceId);
  if (meta == null) return null; // 源已被删除/停用
  MangaSource? src;
  try {
    src = buildSource(meta);
    var result = await src.getChapters(target.itemId);
    var total = result.items.length;
    for (var page = 2; result.hasNext && page <= _maxChapterPages; page++) {
      result = await src.getChapters(target.itemId, page: page);
      if (result.items.isEmpty) break;
      total += result.items.length;
    }
    return total;
  } finally {
    src?.dispose();
  }
}
