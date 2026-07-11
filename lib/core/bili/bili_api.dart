import 'package:dio/dio.dart';

import '../source/models.dart';
import 'bili_auth.dart';
import 'bili_wbi.dart';

/// Bilibili Web API 客户端(番剧向)。所有请求带浏览器 UA + Referer + 已登录 Cookie;
/// 需 WBI 的接口(搜索)先从 nav 拉密钥签名。dio 走 [HttpOverrides.global](= App 代理),
/// 海外/风控走代理出口。返回统一映射成项目的 [Manga]/[Chapter]/[VideoTrack]。
class BiliApi {
  BiliApi._();
  static final BiliApi instance = BiliApi._();

  String _mixinKey = '';
  int _mixinKeyAtSec = 0;
  String _buvid = ''; // 风控指纹 cookie(buvid3/buvid4),搜索缺它会 -412

  /// 合并已登录 Cookie + buvid 指纹,作为请求 Cookie 头。
  String _cookieHeader() => [
        if (BiliAuth.instance.cookie.isNotEmpty) BiliAuth.instance.cookie,
        if (_buvid.isNotEmpty) _buvid,
      ].join('; ');

  Dio _dio() {
    final cookie = _cookieHeader();
    return Dio(BaseOptions(
      headers: {
        'User-Agent': kBiliUa,
        'Referer': 'https://www.bilibili.com/',
        'Origin': 'https://www.bilibili.com',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      },
      validateStatus: (_) => true,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ));
  }

  /// 取 buvid3/buvid4 指纹(x/frontend/finger/spi,无需登录),缓存。B站 WBI 搜索接口
  /// 现强制该指纹 cookie,缺失即 -412「请求被拦截」返回空结果。用不带 Cookie 的裸 dio 拉。
  Future<void> _ensureBuvid() async {
    if (_buvid.isNotEmpty) return;
    try {
      final r = await Dio(BaseOptions(
        headers: {
          'User-Agent': kBiliUa,
          'Referer': 'https://www.bilibili.com/',
        },
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      )).get('https://api.bilibili.com/x/frontend/finger/spi');
      final d = (r.data as Map?)?['data'] as Map?;
      final b3 = d?['b_3'] as String?;
      final b4 = d?['b_4'] as String?;
      _buvid = [
        if (b3 != null && b3.isNotEmpty) 'buvid3=$b3',
        if (b4 != null && b4.isNotEmpty) 'buvid4=$b4',
      ].join('; ');
    } catch (_) {}
  }

  Map<String, dynamic> _body(Response r) {
    final d = r.data;
    if (d is Map) return Map<String, dynamic>.from(d);
    throw Exception('B站返回异常(HTTP ${r.statusCode})');
  }

  /// `x/web-interface/nav`:登录态 + WBI 密钥。未登录也返回 wbi_img。
  Future<Map<String, dynamic>> nav() async {
    final r = await _dio().get('https://api.bilibili.com/x/web-interface/nav');
    final b = _body(r);
    return Map<String, dynamic>.from(b['data'] as Map? ?? const {});
  }

  /// 拉 nav 昵称/登录态,回填 [BiliAuth](展示用)。返回是否已登录。
  Future<bool> refreshProfile() async {
    final d = await nav();
    final isLogin = d['isLogin'] == true;
    if (isLogin) {
      await BiliAuth.instance.setProfile(
        uname: d['uname'] as String?,
        mid: (d['mid'] as num?)?.toInt(),
      );
    }
    return isLogin;
  }

  /// WBI mixin_key,10 分钟缓存(依赖固定当前秒会失效,这里用相对宽的缓存即可)。
  Future<String> _wbiKey({int? nowSec}) async {
    final now = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (_mixinKey.isNotEmpty && now - _mixinKeyAtSec < 600) return _mixinKey;
    final d = await nav();
    final wbi = d['wbi_img'] as Map?;
    final img = wbi?['img_url'] as String?;
    final sub = wbi?['sub_url'] as String?;
    if (img == null || sub == null) throw Exception('取 WBI 密钥失败');
    _mixinKey = biliMixinKey(biliKeyFromUrl(img), biliKeyFromUrl(sub));
    _mixinKeyAtSec = now;
    return _mixinKey;
  }

  static String _https(String? u) {
    if (u == null || u.isEmpty) return '';
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://')) return u.replaceFirst('http://', 'https://');
    return u;
  }

  static final _emTag = RegExp(r'</?em[^>]*>');
  static String _stripEm(String? s) =>
      (s ?? '').replaceAll(_emTag, '').replaceAll('&amp;', '&');

  /// 一条番剧卡片(media_bangumi)→ Manga。search/type 与 search/all/v2 的番剧块同构,共用。
  static Manga? _mapMedia(Map m) {
    final sid = m['season_id'];
    if (sid == null) return null;
    return Manga(
      id: '$sid',
      title: _stripEm(m['title'] as String?),
      cover: _https(m['cover'] as String?),
      description: _stripEm(m['desc'] as String?),
      genres: [
        if ((m['styles'] as String?)?.isNotEmpty ?? false)
          ...('${m['styles']}').split('/').map((e) => e.trim())
      ],
    );
  }

  /// 番剧搜索(WBI 签名)。先用番剧专搜 search/type;个别环境专搜被风控软拦(返回 v_voucher
  /// 空结果)时,回退综合搜索 search/all/v2 抽「番剧」块,尽量还能出结果。
  Future<List<Manga>> searchBangumi(String keyword, int page) async {
    await _ensureBuvid();
    final mk = await _wbiKey();
    final primary = await _searchType(keyword, page, mk);
    if (primary.isNotEmpty) return primary;
    return _searchAllBangumi(keyword, page, mk);
  }

  Future<List<Manga>> _searchType(String keyword, int page, String mk) async {
    final signed = biliWbiSign({
      'search_type': 'media_bangumi',
      'keyword': keyword,
      'page': page,
    }, mk);
    final r = await _dio().get(
      'https://api.bilibili.com/x/web-interface/wbi/search/type',
      queryParameters: signed,
    );
    final list = (_body(r)['data'] as Map?)?['result'] as List? ?? const [];
    return [
      for (final m in list.whereType<Map>())
        if (_mapMedia(m) case final mg?) mg
    ];
  }

  Future<List<Manga>> _searchAllBangumi(
      String keyword, int page, String mk) async {
    final signed = biliWbiSign({'keyword': keyword, 'page': page}, mk);
    final r = await _dio().get(
      'https://api.bilibili.com/x/web-interface/wbi/search/all/v2',
      queryParameters: signed,
    );
    final blocks = (_body(r)['data'] as Map?)?['result'] as List? ?? const [];
    final out = <Manga>[];
    for (final blk in blocks.whereType<Map>()) {
      if (blk['result_type'] != 'media_bangumi') continue;
      for (final m in (blk['data'] as List? ?? const []).whereType<Map>()) {
        final mg = _mapMedia(m);
        if (mg != null) out.add(mg);
      }
    }
    return out;
  }

  /// 我的追番(番剧,type=1)。需登录。
  Future<List<Manga>> followBangumi(int page) async {
    await _ensureBuvid();
    final mid = BiliAuth.instance.mid;
    if (mid <= 0) return const [];
    final r = await _dio().get(
      'https://api.bilibili.com/x/space/bangumi/follow/list',
      queryParameters: {'type': 1, 'pn': page, 'ps': 30, 'vmid': mid},
    );
    final b = _body(r);
    final list = (b['data'] as Map?)?['list'] as List? ?? const [];
    final out = <Manga>[];
    for (final m in list) {
      if (m is! Map) continue;
      final sid = m['season_id'];
      if (sid == null) continue;
      out.add(Manga(
        id: '$sid',
        title: '${m['title'] ?? ''}',
        cover: _https(m['cover'] as String?),
        description: '${m['evaluate'] ?? ''}',
      ));
    }
    return out;
  }

  /// 番剧索引「热门」(按追番人数降序,**无需登录**)。未登录时的默认浏览。
  Future<List<Manga>> indexBangumi(int page) async {
    await _ensureBuvid();
    final r = await _dio().get(
      'https://api.bilibili.com/pgc/season/index/result',
      queryParameters: {
        'st': 1, // 番剧
        'season_type': 1,
        'type': 1,
        'order': 3, // 3=追番人数
        'sort': 0, // 0=降序
        'page': page,
        'pagesize': 20,
      },
    );
    final b = _body(r);
    final list = (b['data'] as Map?)?['list'] as List? ?? const [];
    final out = <Manga>[];
    for (final m in list.whereType<Map>()) {
      final sid = m['season_id'];
      if (sid == null) continue;
      out.add(Manga(
        id: '$sid',
        title: '${m['title'] ?? ''}',
        cover: _https(m['cover'] as String?),
        description: '${m['subTitle'] ?? m['index_show'] ?? ''}',
        status: m['is_finish'] == 1
            ? MangaStatus.completed
            : MangaStatus.ongoing,
      ));
    }
    return out;
  }

  /// 番剧详情 + 分集。[seasonId] 即 Manga.id。
  Future<({Manga manga, List<Chapter> episodes})> season(
      String seasonId) async {
    await _ensureBuvid();
    final r = await _dio().get(
      'https://api.bilibili.com/pgc/view/web/season',
      queryParameters: {'season_id': seasonId},
    );
    final b = _body(r);
    final res = b['result'] as Map?;
    if (res == null) throw Exception('番剧详情为空:${b['message'] ?? ''}');
    final manga = Manga(
      id: seasonId,
      title: '${res['title'] ?? ''}',
      url: 'https://www.bilibili.com/bangumi/play/ss$seasonId',
      cover: _https(res['cover'] as String?),
      description: '${res['evaluate'] ?? ''}',
      genres: [
        // pgc season 的 styles 实测是**纯字符串数组**(["校园","战斗"…]),
        // 但也兼容 [{name}] 形态,逐元素防御性取值,避免硬转 Map 抛错整页失败。
        if ((res['styles'] as List?)?.isNotEmpty ?? false)
          ...((res['styles'] as List)
              .map((e) => e is Map ? '${e['name']}' : '$e'))
      ],
      status: (res['publish'] as Map?)?['is_finish'] == 1
          ? MangaStatus.completed
          : MangaStatus.ongoing,
    );
    final eps = <Chapter>[];
    final list = res['episodes'] as List? ?? const [];
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is! Map) continue;
      final epId = e['ep_id'] ?? e['id'];
      final cid = e['cid'];
      if (epId == null || cid == null) continue;
      final t = '${e['title'] ?? ''}'.trim();
      final long = '${e['long_title'] ?? ''}'.trim();
      final name = long.isNotEmpty
          ? (RegExp(r'^\d+(\.\d+)?$').hasMatch(t) ? '第$t话 $long' : '$t $long')
          : (t.isEmpty ? '第${i + 1}话' : t);
      eps.add(Chapter(
        id: '$epId,$cid',
        name: name,
        url: '${e['share_url'] ?? ''}',
        number: double.tryParse(t) ?? (i + 1).toDouble(),
      ));
    }
    return (manga: manga, episodes: eps);
  }

  static String _dashUrl(Map m) {
    final base = (m['baseUrl'] ?? m['base_url']) as String?;
    if (base != null && base.isNotEmpty) return _https(base);
    final backups = (m['backupUrl'] ?? m['backup_url']) as List?;
    if (backups != null && backups.isNotEmpty) return _https('${backups.first}');
    return '';
  }

  static const _qnLabel = {
    127: '8K',
    126: '杜比视界',
    125: 'HDR',
    120: '4K',
    116: '1080P60',
    112: '1080P+',
    100: '智能修复',
    80: '1080P',
    74: '720P60',
    64: '720P',
    32: '480P',
    16: '360P',
  };

  /// 番剧一集可播放源。DASH(音视频分离)→ 每清晰度一条 [VideoTrack](带 audioUrl);
  /// 老式 durl(整段 mp4/flv)兜底。播放头需 Referer=bilibili + 浏览器 UA。
  Future<List<VideoTrack>> playurl(int epId, int cid) async {
    await _ensureBuvid();
    final r = await _dio().get(
      'https://api.bilibili.com/pgc/player/web/v2/playurl',
      queryParameters: {
        'ep_id': epId,
        'cid': cid,
        'qn': 112,
        'fnval': 4048,
        'fourk': 1,
      },
    );
    final b = _body(r);
    final result = b['result'] as Map? ?? b['data'] as Map?;
    final vi = result?['video_info'] as Map?;
    if (vi == null) {
      throw Exception('取播放源失败:${b['message'] ?? b['code'] ?? ''}');
    }
    const headers = {
      'Referer': 'https://www.bilibili.com/',
      'User-Agent': kBiliUa,
    };

    final dash = vi['dash'] as Map?;
    if (dash != null) {
      final audios = <Map>[
        ...((dash['audio'] as List?) ?? const []).whereType<Map>(),
        // 杜比/无损音轨在 flac / dolby 子对象里,兜底追加。
        if ((dash['flac'] as Map?)?['audio'] is Map)
          (dash['flac'] as Map)['audio'] as Map,
        ...(((dash['dolby'] as Map?)?['audio'] as List?) ?? const [])
            .whereType<Map>(),
      ];
      // 选码率最高的音轨。
      audios.sort((a, b) =>
          ((b['bandwidth'] as num?) ?? 0).compareTo((a['bandwidth'] as num?) ?? 0));
      final audioUrl = audios.isEmpty ? null : _dashUrl(audios.first);

      final byQn = <int, Map>{};
      for (final v in (dash['video'] as List? ?? const []).whereType<Map>()) {
        final id = (v['id'] as num?)?.toInt() ?? 0;
        // 同清晰度多编码取第一条(接口按优选编码排在前)。
        byQn.putIfAbsent(id, () => v);
      }
      final ids = byQn.keys.toList()..sort((a, b) => b.compareTo(a));
      final tracks = <VideoTrack>[
        for (final id in ids)
          VideoTrack(
            url: _dashUrl(byQn[id]!),
            audioUrl: (audioUrl?.isNotEmpty ?? false) ? audioUrl : null,
            quality: _qnLabel[id] ?? 'q$id',
            headers: headers,
            hls: false,
          )
      ];
      if (tracks.isNotEmpty) return tracks;
    }

    // durl 兜底(整段流)。
    final durl = vi['durl'] as List? ?? const [];
    return [
      for (final d in durl.whereType<Map>())
        VideoTrack(
          url: _https(d['url'] as String?),
          quality: _qnLabel[(vi['quality'] as num?)?.toInt() ?? 0] ?? '默认',
          headers: headers,
          hls: false,
        )
    ];
  }
}
