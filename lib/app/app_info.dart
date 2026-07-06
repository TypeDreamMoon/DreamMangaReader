/// App 元信息(关于页 / 调试页共用)。
///
/// [version] 需与 `pubspec.yaml` 的 `version:` 保持一致(手动同步)。
class AppInfo {
  AppInfo._();

  static const name = 'Dream Manga Reader';
  static const cnName = '梦漫';
  static const version = '1.0.0';
  static const tagline = '跨平台漫画阅读器 · Android + Windows';
  static const author = 'TypeDreamMoon';
  static const repoUrl = 'https://github.com/TypeDreamMoon/DreamMangaReader';

  /// 用户可见的功能亮点(关于页展示)。
  static const highlights = <String>[
    '多源聚合:一键混合搜索 / 浏览所有启用的源',
    '瀑布流发现页 + 随机飞入动画',
    '详情页封面主题色(KMeans)+ Bangumi 评分',
    '离线下载 · 阅读进度记忆 · 阅读历史',
    '书架备份 / 恢复 · 源可用性自检',
    '普通 / 日漫 / 滚动三种阅读模式',
    'OLED / Dark / Light 三套主题',
  ];
}
