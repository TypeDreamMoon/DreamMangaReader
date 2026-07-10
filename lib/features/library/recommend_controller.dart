import 'package:flutter/foundation.dart';

import '../../app/library_store.dart';
import '../../core/bangumi/bangumi_api.dart';
import '../../core/log/app_log.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/source_search.dart';
import '../../core/source/title_match.dart' show normalizeTitle;

/// 一条已落到源的推荐:Bangumi 候选(算出来的口味匹配)+ 在源里搜到的可读漫画。
class RecItem {
  RecItem(this.bgm, this.manga, this.meta);
  final BangumiCandidate bgm;
  final Manga manga;
  final SourceMeta meta;
}

/// 书架「为你推荐」引擎。据**收藏 + 在读**的口味(各书匹配到的 Bangumi 题材 tag 汇总)
/// 算内容相似推荐,再用**混合源**把候选搜成可读的漫画。结果内存缓存;书架内容变了
/// (签名变)或手动刷新时才重算,避免每次进书架都联网。
class RecommendController extends ChangeNotifier {
  static const _seedLimit = 12; // 取多少本书当口味「种子」
  static const _candLimit = 18; // 候选池上限
  static const _target = 12; // 最终展示多少条
  static const _bgmConcurrency = 5; // 种子查 Bangumi 的并发
  static const _resolveWorkers = 2; // 候选解析成源漫画的并发(每个再扇出到各源)

  bool _loading = false;
  bool get loading => _loading;
  List<RecItem> _recs = const [];
  List<RecItem> get recs => _recs;
  String? _note; // 空态 / 失败提示(有 recs 时忽略)
  String? get note => _note;
  bool _canRetry = false; // 当前空态是否值得「重试」(失败/暂时性 → 是;书架太少 → 否)
  bool get canRetry => _canRetry;

  String _sig = ''; // 上次**成功算出**推荐时的签名(只缓存成功,失败/空不占缓存)
  LibraryStore? _pending; // 计算途中书架又变了 → 记下,完成后补算一次
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 书架签名:收藏+历史的归一标题 **+ 已启用漫画源** 集合。口味或可用源变了签名才变 →
  /// 该重算(把源纳入:刚配好源 / 启用新源时能自动重出推荐,而非卡在「没有源」空态)。
  static String signatureOf(LibraryStore store) {
    final keys = <String>{
      for (final f in store.favorites) normalizeTitle(f.title),
      for (final h in store.history) normalizeTitle(h.title),
    }..remove('');
    final srcs = [
      for (final s in registeredSources)
        if (s.kind == 'manga' && store.isSourceEnabled(s.id)) s.id,
    ]..sort();
    final sorted = keys.toList()..sort();
    return '${sorted.length}:${sorted.join('|')}#${srcs.join(',')}';
  }

  /// 按需刷新。进行中若签名又变了(或 [force])→ 记 [_pending],本轮完成后补算一次;
  /// 只缓存**成功(有结果)**的签名 —— 失败/空态不占缓存,下次签名变或点重试即可再算。
  Future<void> ensure(LibraryStore store, {bool force = false}) async {
    if (_loading) {
      if (force || signatureOf(store) != _sig) _pending = store;
      return;
    }
    final sig = signatureOf(store);
    if (!force && sig == _sig && _recs.isNotEmpty) return; // 只有成功结果才短路
    _loading = true;
    _note = null;
    _canRetry = false;
    _safeNotify();
    final sw = Stopwatch()..start();
    try {
      final recs = await _compute(store);
      if (_disposed) return;
      _recs = recs;
      if (recs.isNotEmpty) {
        _sig = sig; // 成功才记签名(失败不缓存,留待重试)
      } else if (_note == null) {
        _note = '暂时没算出推荐 · 稍后再试';
        _canRetry = true;
      }
      AppLog.i.info(LogCat.manga,
          '为你推荐 · ${recs.length} 本 · ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      if (!_disposed) {
        _note = '推荐生成失败 · 点重试';
        _canRetry = true;
      }
      AppLog.i.err(LogCat.manga, '为你推荐失败', detail: '$e');
    } finally {
      _loading = false;
      _safeNotify();
      // 计算途中书架/源又变了 → 用最新状态补算一次。
      final p = _pending;
      _pending = null;
      if (p != null && !_disposed) await ensure(p, force: true);
    }
  }

  Future<List<RecItem>> _compute(LibraryStore store) async {
    // ① 种子:收藏(新→旧)+ 历史(新→旧),按归一标题去重,取前 N。
    final seeds = <({String title, String key})>[];
    final seen = <String>{};
    void add(String title, String sid, String mid) {
      final n = normalizeTitle(title);
      if (n.isEmpty || !seen.add(n)) return;
      seeds.add((title: title, key: '$sid:$mid'));
    }

    final favs = [...store.favorites]
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    for (final f in favs) {
      add(f.title, f.sourceId, f.mangaId);
    }
    for (final h in store.history) {
      // history 已按 updatedAt 新→旧
      add(h.title, h.sourceId, h.mangaId);
    }
    if (seeds.length < 2) {
      _note = '书架内容太少 · 先收藏 / 阅读几本漫画';
      return const [];
    }
    final picked = seeds.take(_seedLimit).toList();

    // ② 每颗种子 → Bangumi 条目(有手动绑定用 fromId,否则按标题 lookup)。有限并发。
    final infos = <BangumiInfo>[];
    await _pool(picked, _bgmConcurrency, (s) async {
      final bound = store.bangumiBindingFor(s.key);
      final info =
          bound != null ? await BangumiApi.fromId(bound) : await BangumiApi.lookup(s.title);
      if (info != null) infos.add(info);
    });
    if (infos.length < 2) {
      _note = '没匹配到足够的 Bangumi 条目算口味 · 点重试';
      _canRetry = true; // 多为网络/接口抖动,重试可能就好
      return const [];
    }

    // ③ 口味 → 候选(排除书架里已有的)。
    final excludeNorm = <String>{
      for (final f in store.favorites) normalizeTitle(f.title),
      for (final h in store.history) normalizeTitle(h.title),
    }..remove('');
    final cands = await BangumiApi.recommendForLibrary(infos,
        excludeNorm: excludeNorm, limit: _candLimit);
    if (cands.isEmpty) return const [];

    // ④ 候选 → 混合源解析成可读漫画(有限并发,凑够 target 就停;保候选排序)。
    final metas = [
      for (final s in registeredSources)
        if (s.kind == 'manga' && store.isSourceEnabled(s.id)) s,
    ];
    if (metas.isEmpty) {
      _note = '没有可用的漫画源(先在设置里加源)';
      return const [];
    }
    final resolved = <int, RecItem>{}; // 候选下标 → 解析结果(保排序)
    final resolvedKeys = <String>{}; // 已收 rec 的归一标题(去重)
    var next = 0;
    Future<void> worker() async {
      while (!_disposed && resolved.length < _target) {
        final idx = next++;
        if (idx >= cands.length) return;
        final c = cands[idx];
        final r = await findFirstWork(metas, c.display);
        final m = r.match;
        if (m == null) continue;
        final k = normalizeTitle(m.manga.title);
        if (k.isEmpty || excludeNorm.contains(k) || !resolvedKeys.add(k)) {
          continue;
        }
        if (resolved.length < _target) {
          resolved[idx] = RecItem(c, m.manga, m.meta);
        }
      }
    }

    await Future.wait([for (var w = 0; w < _resolveWorkers; w++) worker()]);
    final ordered = resolved.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [for (final e in ordered) e.value];
  }

  // 有限并发跑一批异步任务。
  static Future<void> _pool<T>(
      List<T> items, int concurrency, Future<void> Function(T) job) async {
    var i = 0;
    Future<void> worker() async {
      while (i < items.length) {
        await job(items[i++]);
      }
    }

    await Future.wait([for (var w = 0; w < concurrency; w++) worker()]);
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }
}
