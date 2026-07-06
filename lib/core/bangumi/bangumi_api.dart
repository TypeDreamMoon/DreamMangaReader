import 'package:dio/dio.dart';

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

  /// 去掉副标题:遇到 ~…~ /(…)/【…】/ 空格 就截断(保留主标题)。
  static String _cleanTitle(String t) {
    var s = t.trim();
    final m = RegExp(r'[~～(（【\[\s]').firstMatch(s);
    if (m != null && m.start >= 2) s = s.substring(0, m.start);
    return s.trim();
  }

  /// 归一化:只留字母/数字/日文假名/汉字(去空格标点),再去数字(卷号)。
  static String _norm(String s) => s
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

  /// 搜索候选列表(手动匹配用)。失败返回空。
  static Future<List<BangumiCandidate>> search(String rawTitle) async {
    final title = _cleanTitle(rawTitle);
    if (title.isEmpty) return const [];
    try {
      final r = await _dio.get<dynamic>(
        'https://api.bgm.tv/search/subject/${Uri.encodeComponent(title)}',
        queryParameters: {
          'type': 1, // 1=书籍(漫画/小说)
          'responseGroup': 'large',
          'max_results': 12,
        },
      );
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
      return const [];
    }
  }

  /// 按条目 id 直接拉完整详情(手动绑定/复用置信匹配结果)。
  static Future<BangumiInfo?> fromId(int id) async {
    try {
      final s = await _dio.get<dynamic>('https://api.bgm.tv/v0/subjects/$id');
      if (s.data is! Map) return null;
      return _fromSubject((s.data as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// 标题自动置信匹配 → 拉完整详情。匹配不上/无评分返回 null。
  static Future<BangumiInfo?> lookup(String rawTitle) async {
    final title = _cleanTitle(rawTitle);
    if (title.length < 2) return null;
    final nq = _norm(title);
    if (nq.length < 2) return null;
    final cands = await search(rawTitle);
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
    final info = await fromId(best.id);
    if (info == null || info.score <= 0) return null; // 没评分不显示
    return info;
  }
}
