import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/source/author_match.dart';

/// 详情页的作者行:每个作者名单独可点,点开「同作者作品」。
///
/// 源的搜索接口只吃关键词,所以整串「A / B」要先用 [AuthorMatch.expand] 拆开,
/// 拿单个作者名去搜才有命中率;拆不出名字(或调用方没给 [onOpenAuthor])就退回纯文本。
///
/// 漫画与番剧详情页原本各抄一份,只差 Key 前缀和点击目标 —— 都收成参数。
/// 小说没有「同作者作品」(那个页面跑在 MangaSource 上),不传 [onOpenAuthor] 即可。
class DetailAuthorLine extends StatelessWidget {
  const DetailAuthorLine({
    super.key,
    required this.authors,
    required this.accent,
    required this.keyPrefix,
    this.onOpenAuthor,
  });

  final List<String> authors;
  final Color accent;

  /// 每个作者名的 Key 前缀(测试定位用),如 `detail-author`。
  final String keyPrefix;

  /// 点某个作者名要干什么;null = 只显示,不可点。
  final ValueChanged<String>? onOpenAuthor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final open = onOpenAuthor;
    final names = open == null ? const <String>[] : AuthorMatch.expand(authors);
    if (open == null || names.isEmpty) {
      return Text(
        context.l10n.detail_authorPrefix(authors.join('、')),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.textMuted, fontSize: 12),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(context.l10n.detail_authorPrefix('').trim(),
            style: TextStyle(color: p.textMuted, fontSize: 12)),
        for (final name in names)
          InkWell(
            key: Key('$keyPrefix-$name'),
            onTap: () => open(name),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Text(
                name,
                style: TextStyle(
                  color: Color.lerp(accent, p.textPrimary, .25),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: accent.withValues(alpha: .5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
