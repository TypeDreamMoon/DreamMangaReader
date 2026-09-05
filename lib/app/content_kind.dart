import 'package:flutter/material.dart' show IconData, Icons;

/// 发现页支持的内容类型。
///
/// **不带展示名**:那是 UI 层的事,由 l10n 取(见 `contentKindLabel`)。枚举里塞
/// 中文字面量会跟着 `disc_comingSoonKind` 之类的模板混进英文/日文界面 ——
/// 「Coming soon: 漫画」就是这么来的。
enum ContentKind {
  manga(Icons.menu_book_rounded, true),
  anime(Icons.movie_rounded, true),
  novel(Icons.auto_stories_rounded, true);

  const ContentKind(this.icon, this.available);

  final IconData icon;

  /// false = 尚未实现,显示占位页。
  final bool available;
}
