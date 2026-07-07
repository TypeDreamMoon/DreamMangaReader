import 'package:flutter/material.dart' show IconData, Icons;

/// 内容类型。当前只有「漫画」可用;「番剧 / 小说」为**预留占位**(后续接入源与页面)。
/// 发现页顶部据此切换;不可用的类型点开显示「即将推出」。
enum ContentKind {
  manga('漫画', Icons.menu_book_rounded, true),
  anime('番剧', Icons.movie_rounded, true),
  novel('小说', Icons.auto_stories_rounded, false);

  const ContentKind(this.label, this.icon, this.available);

  final String label;
  final IconData icon;

  /// false = 尚未实现,显示占位页。
  final bool available;
}
