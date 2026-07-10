import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const _resolveWorkers = 3; // 候选解析成源漫画的并发(findFirstWork 首命中即返,单候选耗时已大降)

  // ---- 缓存:结果落盘(重启秒出)+ Bangumi 种子查询缓存(重算不再逐本联网)----
  static const _kRecCache = 'rec.cache.v1'; // {sig, items:[…]}
  static const _kBgmCache = 'rec.bgmCache.v1'; // normTitle → {id,n,o,t,ts};id=0 表「查不到」
  static const _bgmHitTtlMs = 7 * 24 * 3600 * 1000; // 命中缓存 7 天
  static const _bgmMissTtlMs = 24 * 3600 * 1000; // 「查不到」缓存 1 天(条目可能后补)
  static const _bgmCacheCap = 300;

  SharedPreferences? _prefs;
  bool _cacheLoaded = false;
  Map<String, dynamic> _bgmCache = {};

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
    await _initCache(store); // 读回上次的推荐结果:签名没变就直接用,秒出且零联网
    if (_loading) return; // 等 prefs 期间被并发 ensure 抢跑了
    final sig = signatureOf(store);
    if (!force && sig == _sig && _recs.isNotEmpty) {
      _safeNotify(); // 缓存直出的路径也要通知一次,strip 才会画出来
      return;
    }
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
        _saveRecCache(sig, recs); // 落盘:下次启动直接秒出
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

    // ② 每颗种子 → Bangumi 条目(有手动绑定用 fromId,否则按标题 lookup)。
    // 有限并发 + 7 天缓存:重算时老种子不再逐本联网,只查新加的书。
    final infos = <BangumiInfo>[];
    await _pool(picked, _bgmConcurrency, (s) async {
      final info = await _lookupCached(s.title, store.bangumiBindingFor(s.key));
      if (info != null) infos.add(info);
    });
    _saveBgmCache();
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

  // ---- 缓存 ----

  /// 一次性:读回 Bangumi 查询缓存与上次的推荐结果。结果里源已被删/禁用的条目丢弃。
  Future<void> _initCache(LibraryStore store) async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final p = _prefs ??= await SharedPreferences.getInstance();
      final rawBgm = p.getString(_kBgmCache);
      if (rawBgm != null) {
        _bgmCache = (jsonDecode(rawBgm) as Map).cast<String, dynamic>();
      }
      if (_recs.isNotEmpty) return; // 本会话已有结果,不用旧缓存盖
      final raw = p.getString(_kRecCache);
      if (raw == null) return;
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final items = <RecItem>[];
      for (final e in (j['items'] as List? ?? const [])) {
        if (e is! Map) continue;
        final metaId = e['metaId'] as String?;
        SourceMeta? meta;
        for (final s in registeredSources) {
          if (s.id == metaId) {
            meta = s;
            break;
          }
        }
        if (meta == null || !store.isSourceEnabled(meta.id)) continue;
        items.add(RecItem(
          BangumiCandidate(
            id: (e['bid'] as num?)?.toInt() ?? 0,
            name: e['bn'] as String? ?? '',
            nameCn: e['bc'] as String? ?? '',
            date: '',
            score: (e['bs'] as num?)?.toDouble() ?? 0,
            votes: 0,
            image: '',
          ),
          Manga(
              id: e['mid'] as String? ?? '',
              title: e['mt'] as String? ?? '',
              cover: e['mc'] as String?),
          meta,
        ));
      }
      if (items.isEmpty) return;
      _recs = items;
      // 缓存签名:与当前书架一致 → ensure 短路秒出;不一致 → 先展示旧结果再后台重算。
      _sig = (j['sig'] as String?) ?? '';
    } catch (_) {
      // 缓存坏了就当没有,照常联网算
    }
  }

  void _saveRecCache(String sig, List<RecItem> recs) {
    _prefs?.setString(
        _kRecCache,
        jsonEncode({
          'sig': sig,
          'items': [
            for (final r in recs)
              {
                'bid': r.bgm.id,
                'bn': r.bgm.name,
                'bc': r.bgm.nameCn,
                'bs': r.bgm.score,
                'mid': r.manga.id,
                'mt': r.manga.title,
                'mc': r.manga.cover,
                'metaId': r.meta.id,
              }
          ],
        }));
  }

  /// 带缓存的种子查询。缓存只存推荐算法用得到的字段(id/名称/题材 tag),
  /// 「查不到」也缓存(id=0,短 TTL),免得每次重算都对同一批冷门书白搜一轮。
  Future<BangumiInfo?> _lookupCached(String title, int? boundId) async {
    final key = normalizeTitle(title);
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = key.isEmpty ? null : _bgmCache[key];
    if (hit is Map) {
      final id = (hit['id'] as num?)?.toInt() ?? 0;
      final ts = (hit['ts'] as num?)?.toInt() ?? 0;
      final fresh = now - ts < (id == 0 ? _bgmMissTtlMs : _bgmHitTtlMs);
      final matchesBinding = boundId == null || boundId == id; // 手动绑定优先于缓存
      if (fresh && matchesBinding) {
        if (id == 0) return null;
        return BangumiInfo(
          id: id,
          name: hit['n'] as String? ?? '',
          nameOrig: hit['o'] as String? ?? '',
          score: 0,
          rank: 0,
          votes: 0,
          tags: [for (final t in (hit['t'] as List? ?? const [])) t.toString()],
          summary: '',
          date: '',
          eps: 0,
          volumes: 0,
          image: '',
          infobox: const [],
        );
      }
    }
    // 网络/接口错误会抛出 → 只跳过本次,**不**缓存成「查不到」。否则一次断网
    // 会把所有种子毒成 24 小时的未命中缓存,点「重试」也救不回来。
    BangumiInfo? info;
    try {
      info = boundId != null
          ? await BangumiApi.fromId(boundId, throwOnError: true)
          : await BangumiApi.lookup(title, throwOnError: true);
    } catch (_) {
      return null; // 暂时失败:不写缓存,下次重试真的会重查
    }
    if (key.isNotEmpty) {
      _bgmCache[key] = info == null
          ? {'id': 0, 'ts': now}
          : {
              'id': info.id,
              'n': info.name,
              'o': info.nameOrig,
              // 存过滤后的题材 tag:缓存重建的 info 没有 infobox,原始 tags 会让
              // 作者名混进口味画像(genreTagsOf 对已过滤列表幂等)。
              't': BangumiApi.genreTagsOf(info),
              'ts': now,
            };
    }
    return info;
  }

  void _saveBgmCache() {
    // 超上限按 ts 淘汰最旧。
    if (_bgmCache.length > _bgmCacheCap) {
      int tsOf(String k) =>
          (((_bgmCache[k] as Map?)?['ts'] as num?) ?? 0).toInt();
      final keys = _bgmCache.keys.toList()
        ..sort((a, b) => tsOf(a).compareTo(tsOf(b)));
      for (final k in keys.take(_bgmCache.length - _bgmCacheCap)) {
        _bgmCache.remove(k);
      }
    }
    _prefs?.setString(_kBgmCache, jsonEncode(_bgmCache));
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
