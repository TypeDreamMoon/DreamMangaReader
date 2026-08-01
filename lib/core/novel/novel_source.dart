import '../source/models.dart';
import 'models.dart';

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
