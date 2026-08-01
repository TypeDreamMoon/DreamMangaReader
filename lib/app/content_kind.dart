import 'package:flutter/material.dart' show IconData, Icons;

/// 发现页支持的内容类型。
enum ContentKind {
  manga('漫画', Icons.menu_book_rounded, true),
  anime('番剧', Icons.movie_rounded, true),
  novel('小说', Icons.auto_stories_rounded, true);

  const ContentKind(this.label, this.icon, this.available);

  final String label;
  final IconData icon;

  /// false = 尚未实现,显示占位页。
  final bool available;
}
