import '../source/models.dart';
import '../source/source.dart';
import 'bili_api.dart';
import 'bili_auth.dart';

/// 原生 Bilibili 番剧源。**不是脚本源**——由 source_registry 按 id 直接构造。
/// 复用漫画契约:season_id 当 mangaId、`epId,cid` 当 chapterId;getPages 不用(返回空),
/// 播放走 getVideo → DASH [VideoTrack]。发现页 = 我的追番(需登录),搜索 = 番剧搜索。
class BiliSource implements MangaSource {
  BiliSource();
  final BiliApi _api = BiliApi.instance;

  @override
  String get id => 'bilibili';
  @override
  String get name => '哔哩哔哩';
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => 'https://www.bilibili.com';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;

  @override
  List<FilterDef> get filters => const [];
  @override
  List<SourceSection> get sections => const [];
  @override
  Future<Paged<Manga>> getSection(String sectionId, int page) async =>
      const Paged<Manga>([]);

  @override
  Future<Paged<Manga>> getDiscovery(int page,
      {Map<String, Object?>? filters}) async {
    if (!BiliAuth.instance.isLoggedIn) {
      throw Exception('请先在「哔哩哔哩」扫码登录后查看追番');
    }
    final list = await _api.followBangumi(page);
    return Paged<Manga>(list, hasNext: list.length >= 30);
  }

  @override
  Future<Paged<Manga>> getSearch(String query, int page,
      {Map<String, Object?>? filters}) async {
    final list = await _api.searchBangumi(query, page);
    return Paged<Manga>(list, hasNext: list.isNotEmpty && page < 5);
  }

  @override
  Future<Manga> getMangaDetail(String mangaId) async =>
      (await _api.season(mangaId)).manga;

  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async =>
      Paged<Chapter>((await _api.season(mangaId)).episodes);

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async =>
      const [];

  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) async {
    final parts = episodeId.split(',');
    final epId = int.tryParse(parts.first) ?? 0;
    final cid = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
    if (epId <= 0 || cid <= 0) throw Exception('无效的分集标识:$episodeId');
    return _api.playurl(epId, cid);
  }

  @override
  Future<SourceLogin> login(String username, String password) async =>
      throw UnsupportedError('哔哩哔哩使用扫码登录');

  @override
  void dispose() {}
}
