// 漫画源的数据契约(见 `docs/技术方案.md` §4.3)。纯 Dart,无平台依赖。

enum MangaStatus { unknown, ongoing, completed, hiatus, cancelled }

class Manga {
  final String id; // 源内稳定 id;宿主再前缀 sourceId 形成全局 id
  final String? url; // 网页规范 URL(用于"在浏览器打开")
  final String title;
  final String? cover;
  final List<String> authors;
  final List<String> genres;
  final String? description;
  final MangaStatus status;
  final int? updatedAt; // epoch ms

  const Manga({
    required this.id,
    required this.title,
    this.url,
    this.cover,
    this.authors = const [],
    this.genres = const [],
    this.description,
    this.status = MangaStatus.unknown,
    this.updatedAt,
  });
}

class Chapter {
  final String id;
  final String? url;
  final String name;
  final double? number; // 解析出的话数,用于排序/去重
  final int? publishedAt; // epoch ms

  const Chapter({
    required this.id,
    required this.name,
    this.url,
    this.number,
    this.publishedAt,
  });
}

/// 图片解扰方式。尽量用"数据"描述(由原生 ImagePipeline 执行),
/// 而非把像素逻辑塞进 JS。jmc / rm5 是参考项目里的切片重排。
enum DescrambleKind { none, jmc, rm5, grid }

class Descramble {
  final DescrambleKind kind;
  final Map<String, Object?> params;

  const Descramble(this.kind, [this.params = const {}]);

  static const none = Descramble(DescrambleKind.none);
}

class PageImage {
  final int index;
  final String url; // 宿主去 fetch 的图片 URL
  final Map<String, String>? headers; // 每图的 Referer/UA(防盗链)
  final Descramble descramble;

  const PageImage({
    required this.index,
    required this.url,
    this.headers,
    this.descramble = Descramble.none,
  });
}

/// 分页结果(对应参考项目 handle* 的 canLoadMore / nextPage)。
class Paged<T> {
  final List<T> items;
  final bool hasNext;
  final String? nextCursor;

  const Paged(this.items, {this.hasNext = false, this.nextCursor});
}

class FilterDef {
  final String id;
  final String label;
  final String type; // select | multi | text | sort
  final List<({String value, String label})> options;

  const FilterDef({
    required this.id,
    required this.label,
    required this.type,
    this.options = const [],
  });
}

/// 源的站点特化板块(如 排行榜 / 连载 / 完结 / 漫画大全)。浏览页据此渲染 tab,
/// 每个板块用 [MangaSource.getSection] 分页拉取。默认无板块的源不显示浏览入口。
class SourceSection {
  final String id;
  final String name;

  const SourceSection({required this.id, required this.name});
}
