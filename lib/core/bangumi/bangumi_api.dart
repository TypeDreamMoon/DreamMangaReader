import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import '../source/chinese_fold.dart';
import '../source/title_match.dart' show normalizeTitle, sameCoreKey;

/// Bangumi(番组计划 bgm.tv)条目详情。评分 + 元数据(制作信息、发售、卷话数、简介)。
class BangumiInfo {
  const BangumiInfo({
    required this.id,
    required this.name,
    required this.nameOrig,
    required this.score,
    required this.rank,
    required this.votes,
    required this.tags,
    required this.summary,
    required this.date,
    required this.eps,
    required this.volumes,
    required this.image,
    required this.infobox,
  });

  final int id;
  final String name; // 显示名(优先中文名),给用户核对用
  final String nameOrig; // 原名(与 [name] 不同时才展示,通常是日文原名)
  final double score; // 0~10
  final int rank; // 0 = 无排名
  final int votes; // 评分人数
  final List<String> tags;
  final String summary;
  final String date; // 发售/连载开始日期(可能为空)
  final int eps; // 话数(0=未知)
  final int volumes; // 卷数(0=未知)
  final String image; // 条目封面图 url(可能为空)
  final List<(String, String)> infobox; // 制作信息(作者/出版社/连载状态…)

  String get url => 'https://bgm.tv/subject/$id';
  String get votesLabel => votes >= 10000
      ? '${(votes / 10000).toStringAsFixed(1)}万人评分'
      : '$votes 人评分';
}

/// Bangumi 搜索候选(手动匹配对话框用)。
class BangumiCandidate {
  const BangumiCandidate({
    required this.id,
    required this.name,
    required this.nameCn,
    required this.date,
    required this.score,
    required this.votes,
    required this.image,
  });

  final int id;
  final String name;
  final String nameCn;
  final String date;
  final double score;
  final int votes;
  final String image;

  String get display => nameCn.isNotEmpty ? nameCn : name;
}

/// 用漫画标题去 Bangumi 查评分/元数据。**置信匹配**:标题归一化后要求名称互相包含,
/// 匹配不上宁可返回 null(不显示)也不显示错误条目。无评分(score<=0)也返回 null。
/// 匹配不准时可用 [search] 让用户手动挑,[fromId] 按条目 id 直接拉详情。
class BangumiApi {
  BangumiApi._();

  static const _ua =
      'DreamMangaReader/1.0 (https://github.com/TypeDreamMoon/DreamMangaReader)';

  // 制作信息里挑这些键展示(按此顺序),其余噪音字段忽略。
  static const _infoKeys = <String>[
    '作者',
    '原作',
    '作画',
    '出版社',
    '连载杂志',
    '连载状态',
    '册数',
    '话数',
    '开始',
    '结束',
    '别名',
  ];

  static final Dio _dio = Dio(BaseOptions(
    headers: {'User-Agent': _ua},
    connectTimeout: const Duration(seconds: 12),
    sendTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
    validateStatus: (_) => true,
  ));

  /// 测试用:拿到内部 Dio 换 httpClientAdapter 桩掉网络。
  @visibleForTesting
  static Dio get dioForTesting => _dio;

  /// validateStatus 放行了所有状态码,这里手动把非预期状态还原成错误抛出——
  /// 否则 bgm.tv 一次 5xx/429 会被当成「没搜到/条目不存在」,throwOnError
  /// 调用方(推荐的种子缓存)会把它写成 24 小时的未命中缓存。
  static Never _throwBadStatus(Response<dynamic> r) =>
      throw DioException.badResponse(
        statusCode: r.statusCode ?? 0,
        requestOptions: r.requestOptions,
        response: r,
      );

  /// 去掉副标题:遇到 ~…~ /(…)/【…】/ 空格 就截断(保留主标题)。
  static String _cleanTitle(String t) {
    var s = t.trim();
    final m = RegExp(r'[~～(（【\[\s]').firstMatch(s);
    if (m != null && m.start >= 2) s = s.substring(0, m.start);
    return s.trim();
  }

  /// 归一化:繁→简折叠(条目中文名基本是简体,查询可能是繁体书名),
  /// 只留字母/数字/日文假名/汉字(去空格标点),再去数字(卷号)。
  static String _norm(String s) => ChineseFold.fold(s)
      .toLowerCase()
      .replaceAll(RegExp(r'[^0-9a-z぀-ヿ一-鿿]'), '')
      .replaceAll(RegExp(r'\d'), '');

  /// 置信匹配。**容繁简**:同字形走子串包含;异字形(繁体查询 vs 简体条目名)
  /// 走字符集重叠率——覆盖查询 ≥45% 且交集 ≥3 字才认(既接住繁简,又挡掉无关条目)。
  static bool _confident(String nq, String candidate) {
    final nc = _norm(candidate);
    if (nc.isEmpty || nq.isEmpty) return false;
    if (nc.contains(nq) || nq.contains(nc)) {
      return (nq.length < nc.length ? nq.length : nc.length) >= 2;
    }
    final qs = nq.split('').toSet();
    final cs = nc.split('').toSet();
    var inter = 0;
    for (final ch in qs) {
      if (cs.contains(ch)) inter++;
    }
    final ratio = qs.isEmpty ? 0.0 : inter / qs.length;
    return inter >= 3 && ratio >= 0.45;
  }

  static String _img(dynamic images) {
    if (images is Map) {
      for (final k in const ['common', 'large', 'medium', 'grid', 'small']) {
        final v = images[k];
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return '';
  }

  /// 解析 infobox(制作信息)。value 可能是字符串或 `[{v: ...}]` 列表。
  static List<(String, String)> _parseInfobox(dynamic box) {
    if (box is! List) return const [];
    final map = <String, String>{};
    for (final it in box) {
      if (it is! Map) continue;
      final k = (it['key'] ?? '').toString();
      if (k.isEmpty) continue;
      final v = it['value'];
      String val;
      if (v is String) {
        val = v;
      } else if (v is List) {
        val = v
            .map((e) => e is Map ? (e['v'] ?? e['k'] ?? '').toString() : '$e')
            .where((s) => s.isNotEmpty)
            .join(' / ');
      } else {
        val = v?.toString() ?? '';
      }
      val = val.trim();
      if (val.isNotEmpty && !map.containsKey(k)) map[k] = val;
    }
    final out = <(String, String)>[];
    for (final k in _infoKeys) {
      final v = map[k];
      if (v != null) out.add((k, v));
    }
    return out;
  }

  static BangumiInfo? _fromSubject(Map<String, dynamic> sd) {
    final id = (sd['id'] as num?)?.toInt();
    if (id == null) return null;
    final rating = (sd['rating'] as Map?) ?? const {};
    final score = (rating['score'] as num?)?.toDouble() ?? 0;
    final rank = (rating['rank'] as num?)?.toInt() ?? 0;
    final votes = (rating['total'] as num?)?.toInt() ?? 0;
    final nameOrig = (sd['name'] ?? '').toString();
    final nameCn = (sd['name_cn'] ?? '').toString();
    final name = nameCn.isNotEmpty ? nameCn : nameOrig;
    final tags = ((sd['tags'] as List?) ?? const [])
        .take(10)
        .map((t) => (t is Map ? (t['name'] ?? '') : '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
    return BangumiInfo(
      id: id,
      name: name,
      nameOrig: nameOrig == name ? '' : nameOrig,
      score: score,
      rank: rank,
      votes: votes,
      tags: tags,
      summary: (sd['summary'] ?? '').toString().trim(),
      date: (sd['date'] ?? '').toString(),
      eps: (sd['eps'] as num?)?.toInt() ?? 0,
      volumes: (sd['volumes'] as num?)?.toInt() ?? 0,
      image: _img(sd['images']),
      infobox: _parseInfobox(sd['infobox']),
    );
  }

  /// 搜索候选列表(手动匹配用)。失败返回空;[throwOnError]=true 时网络/接口错误
  /// 改为抛出——调用方需要区分「真没搜到」和「暂时失败」(如推荐的未命中缓存)。
  ///
  /// **繁体书名先折简体再搜**:Bangumi 条目中文名基本是简体,繁体直搜常只回无关
  /// 结果(穿越者的幸運禮 搜不到 穿越者的幸运礼,线上实测)。折叠命中排前,
  /// 原文再搜一次补漏(港台版条目),按 id 去重合并。
  static Future<List<BangumiCandidate>> search(String rawTitle,
      {bool throwOnError = false}) async {
    final title = _cleanTitle(rawTitle);
    if (title.isEmpty) return const [];
    final folded = ChineseFold.fold(title);
    final queries = folded == title ? [title] : [folded, title];
    final out = <BangumiCandidate>[];
    final seen = <int>{};
    for (final q in queries) {
      for (final c in await _searchOne(q, throwOnError: throwOnError)) {
        if (seen.add(c.id)) out.add(c);
      }
    }
    return out;
  }

  /// 单次关键词搜索(不折叠;非 200 一律算接口错误,按 [throwOnError] 抛出或返回空)。
  static Future<List<BangumiCandidate>> _searchOne(String title,
      {bool throwOnError = false}) async {
    try {
      final r = await _dio.get<dynamic>(
        'https://api.bgm.tv/search/subject/${Uri.encodeComponent(title)}',
        queryParameters: {
          'type': 1, // 1=书籍(漫画/小说)
          'responseGroup': 'large',
          'max_results': 12,
        },
      );
      if (r.statusCode != 200) _throwBadStatus(r);
      final data = r.data;
      if (data is! Map) return const [];
      final list = (data['list'] as List?) ?? const [];
      final out = <BangumiCandidate>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final x = raw.cast<String, dynamic>();
        final id = (x['id'] as num?)?.toInt();
        if (id == null) continue;
        final rating = (x['rating'] as Map?) ?? const {};
        out.add(BangumiCandidate(
          id: id,
          name: (x['name'] ?? '').toString(),
          nameCn: (x['name_cn'] ?? '').toString(),
          date: (x['air_date'] ?? '').toString(),
          score: (rating['score'] as num?)?.toDouble() ?? 0,
          votes: (rating['total'] as num?)?.toInt() ?? 0,
          image: _img(x['images']),
        ));
      }
      return out;
    } catch (_) {
      if (throwOnError) rethrow;
      return const [];
    }
  }

  /// 按条目 id 直接拉完整详情(手动绑定/复用置信匹配结果)。
  /// [throwOnError]=true 时网络/接口错误抛出(区分「条目不存在」与「暂时失败」):
  /// 404 是真的「条目不存在」→ 返回 null(调用方可放心缓存),5xx/429 才抛。
  static Future<BangumiInfo?> fromId(int id, {bool throwOnError = false}) async {
    try {
      final s = await _dio.get<dynamic>('https://api.bgm.tv/v0/subjects/$id');
      if (s.statusCode == 404) return null; // 条目不存在
      if (s.statusCode != 200) _throwBadStatus(s);
      if (s.data is! Map) return null;
      return _fromSubject((s.data as Map).cast<String, dynamic>());
    } catch (_) {
      if (throwOnError) rethrow;
      return null;
    }
  }

  /// 标题自动置信匹配 → 拉完整详情。匹配不上/无评分返回 null。
  /// [throwOnError]=true 时网络/接口错误抛出——null 就真的只表示「没匹配上」。
  static Future<BangumiInfo?> lookup(String rawTitle,
      {bool throwOnError = false}) async {
    final title = _cleanTitle(rawTitle);
    if (title.length < 2) return null;
    final nq = _norm(title);
    if (nq.length < 2) return null;
    final cands = await search(rawTitle, throwOnError: throwOnError);
    // 置信匹配里挑评分人数最多的(主条目通常票最多)。
    BangumiCandidate? best;
    var bestVotes = -1;
    for (final c in cands) {
      if (!_confident(nq, c.name) && !_confident(nq, c.nameCn)) continue;
      if (c.votes > bestVotes) {
        bestVotes = c.votes;
        best = c;
      }
    }
    if (best == null) return null;
    final info = await fromId(best.id, throwOnError: throwOnError);
    if (info == null || info.score <= 0) return null; // 没评分不显示
    return info;
  }

  /// 相关推荐(**基于题材 tag 的内容相似度**,而非 Bangumi 的「相关条目」——后者多是
  /// 同系列番外/资料集,不算"相似作")。步骤:
  ///   ① 抽取本作的题材 tag(剔除 漫画/作者/书名/连载状态 等无区分度的);
  ///   ② 用这些 tag 做几组「与」搜索凑候选池(各结果自带 tags/评分,免逐条再请求);
  ///   ③ 打分 = 与本作**题材 tag 的加权重叠**(泛 tag 权重低)为主 + 评分微调破平;
  ///   ④ **排除同系列/衍生**(Bangumi 相关条目 id + 同名/含书名者)与自身。
  /// 题材 tag 不足时退回「相关条目」兜底。截断 [limit]。
  static Future<List<BangumiCandidate>> recommend(BangumiInfo bgm,
      {int limit = 12}) async {
    final genre = _genreTags(bgm);
    if (genre.isEmpty) return _relatedFallback(bgm, limit);
    final sourceSet = genre.toSet();
    final nameNorm = normalizeTitle(bgm.name);
    final origNorm = normalizeTitle(bgm.nameOrig);

    // 同系列/衍生排除集(番外/资料集等 → Bangumi「相关条目」的 id)。
    final exclude = <int>{bgm.id};
    try {
      final r = await _dio
          .get<dynamic>('https://api.bgm.tv/v0/subjects/${bgm.id}/subjects');
      if (r.data is List) {
        for (final x in r.data as List) {
          final id = x is Map ? (x['id'] as num?)?.toInt() : null;
          if (id != null) exclude.add(id);
        }
      }
    } catch (_) {}

    // 候选池:多 tag「与」搜索(精准)+ 单 tag(广)。结果自带 tags 用于打分。
    final pool = <int, ({BangumiCandidate cand, List<String> tags})>{};
    Future<void> searchTags(List<String> tags) async {
      if (tags.isEmpty) return;
      try {
        final r = await _dio.post<dynamic>(
          'https://api.bgm.tv/v0/search/subjects',
          queryParameters: {'limit': 25},
          data: {
            'keyword': '',
            'sort': 'rank',
            'filter': {
              'type': [1],
              'tag': tags,
            },
          },
        );
        final d = r.data;
        if (d is Map && d['data'] is List) {
          for (final raw in d['data'] as List) {
            if (raw is! Map) continue;
            final c = _candidateFromV0(raw);
            if (c == null || c.display.isEmpty) continue;
            final ctags = ((raw['tags'] as List?) ?? const [])
                .map((t) => t is Map ? (t['name'] ?? '').toString() : '')
                .where((s) => s.isNotEmpty)
                .toList();
            pool[c.id] = (cand: c, tags: ctags);
          }
        }
      } catch (_) {}
    }

    await searchTags(genre.take(2).toList()); // 前两题材「与」→ 最相似
    if (genre.length >= 3) await searchTags([genre[0], genre[2]]); // 换个组合
    await searchTags([genre.first]); // 广一点

    // 打分 + 过滤同系列/同名。
    final scored = <({BangumiCandidate cand, double score})>[];
    for (final e in pool.values) {
      if (exclude.contains(e.cand.id)) continue;
      // 同名/衍生(名字互相包含)→ 同一作品的番外,剔掉。
      final cn = normalizeTitle(e.cand.display);
      if (cn.isEmpty) continue;
      if (nameNorm.isNotEmpty && (cn.contains(nameNorm) || nameNorm.contains(cn))) {
        continue;
      }
      if (origNorm.isNotEmpty && (cn.contains(origNorm) || origNorm.contains(cn))) {
        continue;
      }
      var overlap = 0.0;
      for (final t in e.tags) {
        if (sourceSet.contains(t)) {
          overlap += _commonGenre.contains(t) ? 0.5 : 1.0; // 泛 tag 权重低
        }
      }
      if (overlap < 1.0) continue; // 至少 1 个有区分度的题材,或 2 个泛题材
      scored.add((cand: e.cand, score: overlap * 10 + e.cand.score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    // 去重:同一作品的不同卷 / 版本(如「阿波連さん (2)(3)」)只留评分最高的一个;
    // 展示名也剥掉卷号 / 版本后缀(卡片更干净,点开去源里搜也更容易命中正作)。
    final keptKeys = <String>[];
    final out = <BangumiCandidate>[];
    for (final e in scored) {
      final k = normalizeTitle(_stripVolEd(e.cand.display));
      // 繁简 / 异体 / 语种版本(如「狼与香辛料」vs「狼と香辛料」)也算同作 → 去掉。
      if (k.isEmpty || keptKeys.any((kk) => kk == k || sameCoreKey(k, kk))) {
        continue;
      }
      keptKeys.add(k);
      out.add(_cleanRec(e.cand));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// **书架级推荐**:把多本「种子」(收藏 / 在读书匹配到的 Bangumi 条目)的题材 tag
  /// 汇总成口味画像,再按画像做几组 tag「与」搜索凑候选,按**画像加权重叠**打分。
  ///   - [excludeNorm]:书架里已有的书(归一化标题),不再推荐;
  ///   - 排除种子自身 id 与和种子同名 / 衍生的;去重卷号 / 繁简同作。截断 [limit]。
  /// 种子没有可用题材 tag(画像为空)时返回空。
  static Future<List<BangumiCandidate>> recommendForLibrary(
    List<BangumiInfo> seeds, {
    required Set<String> excludeNorm,
    int limit = 12,
  }) async {
    // ① 口味画像:各种子题材 tag 加权计数(有区分度的权重高、泛 tag 减半)。
    final profile = <String, double>{};
    for (final s in seeds) {
      for (final t in _genreTags(s)) {
        profile[t] = (profile[t] ?? 0) + (_commonGenre.contains(t) ? 0.5 : 1.0);
      }
    }
    if (profile.isEmpty) return const [];
    final topTags = profile.keys.toList()
      ..sort((a, b) => profile[b]!.compareTo(profile[a]!));

    final excludeIds = <int>{for (final s in seeds) s.id};
    final seedNames = <String>[
      for (final s in seeds) ...[
        normalizeTitle(s.name),
        normalizeTitle(s.nameOrig),
      ],
    ].where((e) => e.isNotEmpty).toList();

    // ② 候选池:画像里最靠前的 tag 做几组「与」搜索(精准 + 广撒)。
    final pool = <int, ({BangumiCandidate cand, List<String> tags})>{};
    Future<void> searchTags(List<String> tags) async {
      tags = tags.where((t) => t.isNotEmpty).toList();
      if (tags.isEmpty) return;
      try {
        final r = await _dio.post<dynamic>(
          'https://api.bgm.tv/v0/search/subjects',
          queryParameters: {'limit': 25},
          data: {
            'keyword': '',
            'sort': 'rank',
            'filter': {
              'type': [1],
              'tag': tags,
            },
          },
        );
        final d = r.data;
        if (d is Map && d['data'] is List) {
          for (final raw in d['data'] as List) {
            if (raw is! Map) continue;
            final c = _candidateFromV0(raw);
            if (c == null || c.display.isEmpty) continue;
            final ctags = ((raw['tags'] as List?) ?? const [])
                .map((t) => t is Map ? (t['name'] ?? '').toString() : '')
                .where((s) => s.isNotEmpty)
                .toList();
            pool[c.id] = (cand: c, tags: ctags);
          }
        }
      } catch (_) {}
    }

    if (topTags.length >= 2) await searchTags([topTags[0], topTags[1]]);
    if (topTags.length >= 3) await searchTags([topTags[0], topTags[2]]);
    if (topTags.length >= 4) await searchTags([topTags[1], topTags[3]]);
    await searchTags([topTags[0]]);
    if (topTags.length >= 2) await searchTags([topTags[1]]);

    // ③ 打分 + 过滤(库里已有、种子同名、衍生)。
    final scored = <({BangumiCandidate cand, double score})>[];
    for (final e in pool.values) {
      if (excludeIds.contains(e.cand.id)) continue;
      final cn = normalizeTitle(e.cand.display);
      if (cn.isEmpty || excludeNorm.contains(cn)) continue;
      if (seedNames.any((n) => cn.contains(n) || n.contains(cn))) continue;
      var overlap = 0.0;
      for (final t in e.tags) {
        final w = profile[t];
        if (w != null) overlap += w; // 命中口味 tag → 按画像权重累加
      }
      if (overlap < 1.0) continue; // 至少一个有区分度的题材命中
      scored.add((cand: e.cand, score: overlap * 5 + e.cand.score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    // ④ 去重(卷号 / 繁简同作)+ 再挡一次库里已有(用剥卷号后的归一)。
    final keptKeys = <String>[];
    final out = <BangumiCandidate>[];
    for (final e in scored) {
      final k = normalizeTitle(_stripVolEd(e.cand.display));
      if (k.isEmpty || excludeNorm.contains(k)) continue;
      if (keptKeys.any((kk) => kk == k || sameCoreKey(k, kk))) continue;
      keptKeys.add(k);
      out.add(_cleanRec(e.cand));
      if (out.length >= limit) break;
    }
    return out;
  }

  static final _editionRe = RegExp(
      r'\s*(愛蔵版|愛藏版|爱藏版|完全版|新装版|新裝版|文库版|文庫版|典藏版|收藏版|珍藏版|合本|豪华版|豪華版|复刻版|復刻版)\s*$');

  /// 剥掉卷号 / 版本后缀:「爆漫王。 (18) 副标题」→「爆漫王。」、「… 愛蔵版」→「…」。
  static String _stripVolEd(String s) {
    var x = s.trim();
    // 括号卷号(及其后的卷标题)到结尾:「 (18) 余裕与赶稿地狱」。
    x = x
        .replaceAll(
            RegExp(r'\s*[(（\[【]\s*(?:vol\.?\s*)?\d+\s*(?:卷|巻|册|冊)?\s*[)）\]】].*$',
                caseSensitive: false),
            '')
        .trim();
    x = x.replaceAll(RegExp(r'\s*第\s*\d+\s*[卷巻册冊].*$'), '').trim(); // 第N卷→尾
    x = x.replaceAll(_editionRe, '').trim();
    return x.isEmpty ? s.trim() : x;
  }

  /// 展示用:把候选的名字剥掉卷号 / 版本(id/评分/封面不动)。
  static BangumiCandidate _cleanRec(BangumiCandidate c) => BangumiCandidate(
        id: c.id,
        name: _stripVolEd(c.name),
        nameCn: _stripVolEd(c.nameCn),
        date: c.date,
        score: c.score,
        votes: c.votes,
        image: c.image,
      );

  /// 无题材 tag 时的兜底:Bangumi「相关条目」里的书籍。
  static Future<List<BangumiCandidate>> _relatedFallback(
      BangumiInfo bgm, int limit) async {
    final seen = <int>{bgm.id};
    final out = <BangumiCandidate>[];
    try {
      final r = await _dio
          .get<dynamic>('https://api.bgm.tv/v0/subjects/${bgm.id}/subjects');
      if (r.data is List) {
        for (final raw in r.data as List) {
          if (raw is! Map || (raw['type'] as num?)?.toInt() != 1) continue;
          final c = _candidateFromV0(raw);
          if (c != null && c.display.isNotEmpty && seen.add(c.id)) out.add(c);
        }
      }
    } catch (_) {}
    return out.take(limit).toList();
  }

  static BangumiCandidate? _candidateFromV0(Map raw) {
    final id = (raw['id'] as num?)?.toInt();
    if (id == null) return null;
    final rating = (raw['rating'] as Map?) ?? const {};
    return BangumiCandidate(
      id: id,
      name: (raw['name'] ?? '').toString(),
      nameCn: (raw['name_cn'] ?? '').toString(),
      date: (raw['date'] ?? raw['air_date'] ?? '').toString(),
      score: (rating['score'] as num?)?.toDouble() ?? 0,
      votes: (rating['total'] as num?)?.toInt() ?? 0,
      image: _img(raw['images']),
    );
  }

  // 无区分度的 tag(载体/地区/连载状态/媒介):不作题材相似依据。
  static const _tagSkip = {
    '漫画', '漫畫', '小说', '小說', '轻小说', '輕小說', 'web漫画', '网络漫画', '连载漫画',
    '单行本', '轻小说分卷', 'web小说', '日本', '中国', '中國', '韩国', '韓國', '美国',
    '美國', '欧美', '港台', '台湾', '香港', '连载', '完结', '連載', '完結', '连载中',
    'tv', 'ova', 'oad', '剧场版', '劇場版', '短片', 'comic', 'manga',
  };

  // 太泛的题材:算相似时权重减半(避免只共一个「奇幻」就当很像)。
  static const _commonGenre = {
    '奇幻', '冒险', '冒險', '热血', '熱血', '战斗', '戰鬥', '恋爱', '戀愛', '爱情',
    '愛情', '搞笑', '喜剧', '喜劇', '日常', '校园', '校園', '治愈', '治癒', '后宫',
    '後宮', '科幻', '悬疑', '懸疑', '少年', '少女', '青年',
  };

  /// 公开版 [_genreTags]:推荐的种子缓存要存**过滤后**的题材 tag——
  /// 过滤依赖 infobox(剔作者/出版社名),缓存重建的 BangumiInfo 没有 infobox,
  /// 存原始 tags 会让作者名混进口味画像。对已过滤列表重过滤是幂等的。
  static List<String> genreTagsOf(BangumiInfo bgm) => _genreTags(bgm);

  /// 抽取本作的「题材」tag(用于相似度):剔除载体/地区/连载状态、作者名、书名类、单字。
  /// 保序(Bangumi 按 tag 计数降序,越靠前越主流),取前若干。
  static List<String> _genreTags(BangumiInfo bgm) {
    final out = <String>[];
    final nameNorm = normalizeTitle(bgm.name);
    final origNorm = normalizeTitle(bgm.nameOrig);
    for (final t in bgm.tags) {
      if (t.length < 2) continue;
      if (_tagSkip.contains(t.toLowerCase())) continue;
      final tn = normalizeTitle(t);
      if (tn.isEmpty) continue;
      if (nameNorm.isNotEmpty && (nameNorm.contains(tn) || tn.contains(nameNorm))) {
        continue; // 书名/含书名的 tag
      }
      if (origNorm.isNotEmpty && (origNorm.contains(tn) || tn.contains(origNorm))) {
        continue;
      }
      if (bgm.infobox.any((e) => e.$2.contains(t))) continue; // 作者/出版社/杂志等
      out.add(t);
      if (out.length >= 8) break;
    }
    return out;
  }
}
