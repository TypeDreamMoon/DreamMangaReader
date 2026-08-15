import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/source/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../novel/novel_cover.dart';
import 'manga_cover.dart';
import 'shelf_item.dart';

/// 类型 → 图标 / 文案。书架筛选条和卡片角标共用,新增内容类型只改这里。
IconData shelfKindIcon(ShelfKind kind) => switch (kind) {
      ShelfKind.manga => Icons.menu_book_rounded,
      ShelfKind.novel => Icons.auto_stories_rounded,
      ShelfKind.anime => Icons.movie_rounded,
    };

String shelfKindLabel(BuildContext context, ShelfKind kind) =>
    switch (kind) {
      ShelfKind.manga => context.l10n.libraryKindManga,
      ShelfKind.novel => context.l10n.libraryKindNovel,
      ShelfKind.anime => context.l10n.libraryKindAnime,
    };

/// 按内容类型派发封面:漫画/番剧走 [MangaCover](带源 Referer、「N源」角标),
/// 小说走 [NovelCover](本地生成封面)。三类在同一个网格里混排,尺寸口径必须一致,
/// 所以纵横比/圆角/点击态都在这里统一,不留给各调用点自己拼。
class ShelfCover extends StatelessWidget {
  const ShelfCover({
    super.key,
    required this.kind,
    required this.id,
    required this.title,
    this.cover,
    this.authors = const [],
    this.sourceId,
    this.radius,
    this.aspect = 3 / 4,
    this.sourceCount = 1,
    this.heroTag,
    this.onTap,
  });

  /// 从一条书架收藏建封面(收藏网格/搜索结果用)。
  factory ShelfCover.item(
    ShelfItem item, {
    double? radius,
    double aspect = 3 / 4,
    Object? heroTag,
    VoidCallback? onTap,
  }) =>
      ShelfCover(
        kind: item.kind,
        id: shelfItemId(item),
        title: item.title,
        cover: item.cover,
        authors: item.novelEntry?.authors ?? const [],
        sourceId: item.mangaEntry?.sourceId ?? item.animeEntry?.sourceId,
        radius: radius,
        aspect: aspect,
        sourceCount: item.sourceCount,
        heroTag: heroTag,
        onTap: onTap,
      );

  final ShelfKind kind;

  /// 稳定 id:驱动占位渐变(同一本书永远同一个色),小说用它当 [Novel.id]。
  final String id;
  final String title;
  final String? cover;
  final List<String> authors;
  final String? sourceId;
  final double? radius;
  final double aspect;
  final int sourceCount;
  final Object? heroTag;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (kind != ShelfKind.novel) {
      return MangaCover(
        manga: Manga(id: id, title: title, cover: cover),
        headers: imageHeadersFor(sourceId),
        sourceCount: sourceCount,
        radius: radius,
        aspect: aspect,
        heroTag: heroTag,
        onTap: onTap,
      );
    }
    // 小说封面组件自身不带点击态/悬停,包一层 Pressable 与漫画封面对齐。
    // NovelCover 内部已 ExcludeSemantics(纯装饰),所以点击目标的名字得在这里给,
    // 否则读屏只会念到「按钮」而不知道是哪一本 —— 与 MangaCover 同一口径。
    return Semantics(
      label: title,
      button: onTap != null,
      child: Pressable(
        onTap: onTap,
        hoverElevate: true,
        child: NovelCover(
          novel: Novel(id: id, title: title, cover: cover, authors: authors),
          radius: radius ?? LibraryScope.read(context).coverRadius,
          aspect: aspect,
          heroTag: heroTag,
        ),
      ),
    );
  }
}

/// 条目所属源 id。本地导入的小说没有源,给个稳定占位。
String shelfItemSourceId(ShelfItem item) => switch (item.kind) {
      ShelfKind.manga => item.mangaEntry!.sourceId,
      ShelfKind.anime => item.animeEntry!.sourceId,
      ShelfKind.novel => item.novelEntry!.sourceId ?? 'local',
    };

/// 小说的 [Novel.id] 口径与详情页保持一致(novelId → 指纹 → key)。
String shelfItemId(ShelfItem item) => switch (item.kind) {
      ShelfKind.manga => item.mangaEntry!.mangaId,
      ShelfKind.anime => item.animeEntry!.animeId,
      ShelfKind.novel => item.novelEntry!.novelId ??
          item.novelEntry!.fingerprint ??
          item.novelEntry!.key,
    };

/// 类型角标:混排(筛选=全部)时贴在封面左下,告诉用户这张卡是哪一类。
/// 已经按类型筛选过就没必要重复标注,由调用方决定显不显示。
class ShelfKindBadge extends StatelessWidget {
  const ShelfKindBadge({super.key, required this.kind});

  final ShelfKind kind;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: p.elevated.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(shelfKindIcon(kind), size: 10, color: p.accent),
          const SizedBox(width: 3),
          Text(
            shelfKindLabel(context, kind),
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 9.5,
              height: 1.0,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// 追更角标:右上角一颗数字点,表示这本有几话没看过。
///
/// 只显示数字不带单位 —— 角标就那么大,而「话/集/章」三类叫法还不一样;
/// 完整语义交给 [Semantics.label](读屏会念「3 话新」),视觉上数字最省地方。
class ShelfUpdateBadge extends StatelessWidget {
  const ShelfUpdateBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 三位数以上没有意义,而且会把角标撑变形。
    final text = count > 99 ? '99+' : '$count';
    return Semantics(
      label: context.l10n.shelf_newChapters(count),
      child: Container(
        constraints: const BoxConstraints(minWidth: 18),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: p.accent,
          borderRadius: BorderRadius.circular(9),
          // 深色封面上贴亮角标容易糊在一起,描一圈底色把它托起来。
          border: Border.all(color: p.background.withValues(alpha: 0.55)),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: p.onAccent,
            fontSize: 10,
            height: 1.1,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// 封面 + 左下类型角标 + 右上追更角标。两个角标都不需要时原样返回封面
/// (不多包一层 Stack)。
Widget shelfCoverWithBadge({
  required Widget cover,
  required ShelfKind kind,
  required bool showKind,
  int pending = 0,
}) {
  if (!showKind && pending <= 0) return cover;
  return Stack(
    children: [
      cover,
      if (showKind)
        Positioned(left: 6, bottom: 6, child: ShelfKindBadge(kind: kind)),
      if (pending > 0)
        Positioned(right: 5, top: 5, child: ShelfUpdateBadge(count: pending)),
    ],
  );
}
