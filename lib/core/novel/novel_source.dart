import '../source/models.dart';
import '../source/source_registry.dart';
import 'models.dart';

/// 由源元信息造一个小说源引擎。详情页/浏览页/换源弹层都靠它注入实现(测试可替换)。
typedef NovelSourceFactory = NovelSource Function(SourceMeta meta);

abstract interface class NovelSource {
  String get id;
  String get name;
  List<FilterDef> get filters;
  List<SourceSection> get sections;

  Future<Paged<Novel>> getNovelDiscovery(
    int page, {
    Map<String, Object?>? filters,
  });
  Future<Paged<Novel>> getNovelSection(String sectionId, int page);
  Future<Paged<Novel>> getNovelSearch(
    String query,
    int page, {
    Map<String, Object?>? filters,
  });
  Future<Novel> getNovelDetail(String novelId);
  Future<Paged<NovelChapter>> getNovelChapters(String novelId, {int? page});
  Future<NovelDocument> getNovelDocument(String novelId, String chapterId);
  void dispose();
}
