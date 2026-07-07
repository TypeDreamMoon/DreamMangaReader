import 'models.dart';
import 'source.dart';

/// 纯本地演示源,用于验证 [MangaSource] 契约端到端跑通(不联网)。
/// 真源改为通过 `host.http.fetch` + HTML 解析实现,结构一致。
class HelloSource implements MangaSource {
  HelloSource(this._host);

  final HostApi _host;

  @override
  String get id => 'hello';
  @override
  String get name => 'Hello 演示源';
  @override
  String get lang => 'zh-Hans';
  @override
  String get baseUrl => 'https://example.com';
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

  static const _titles = [
    '墨染之约',
    '银河剑客',
    '雾之国',
    '霓虹默示录',
    '青碧之海',
    '山海绘卷',
  ];

  @override
  Future<Paged<Manga>> getDiscovery(int page, {Map<String, Object?>? filters}) async {
    _host.log('info', 'getDiscovery(page=$page)');
    final items = <Manga>[
      for (var i = 0; i < _titles.length; i++)
        Manga(
          id: 'm$i',
          title: _titles[i],
          authors: const ['青行灯'],
          status: MangaStatus.ongoing,
        ),
    ];
    return Paged(items);
  }

  @override
  Future<Paged<Manga>> getSearch(String query, int page,
      {Map<String, Object?>? filters}) async {
    final all = (await getDiscovery(page)).items;
    return Paged(all.where((m) => m.title.contains(query)).toList());
  }

  @override
  Future<Manga> getMangaDetail(String mangaId) async => Manga(
        id: mangaId,
        title: '墨染之约',
        authors: const ['青行灯'],
        genres: const ['奇幻'],
        status: MangaStatus.ongoing,
        description: '演示详情数据。',
      );

  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async => Paged(<Chapter>[
        for (var i = 128; i >= 1; i--)
          Chapter(id: 'c$i', name: '第 $i 话', number: i.toDouble()),
      ]);

  @override
  Future<List<PageImage>> getPages(String mangaId, String chapterId) async => <PageImage>[
        for (var i = 0; i < 18; i++)
          PageImage(index: i, url: 'https://example.com/$chapterId/$i.jpg'),
      ];

  @override
  Future<List<VideoTrack>> getVideo(String animeId, String episodeId) async =>
      throw UnsupportedError('演示源不支持视频播放');

  @override
  Future<SourceLogin> login(String username, String password) async =>
      throw UnsupportedError('演示源不支持登录');

  @override
  void dispose() {}
}
