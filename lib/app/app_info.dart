/// App 元信息(关于页 / 调试页共用)。
///
/// [version] = 用户可见的发布版本(含预发布后缀,与 git tag 对齐);
/// pubspec.yaml 的 `version:` 保持纯数字 `x.y.z+n`(驱动 versionCode / Windows 版本号,
/// 不能带 `-beta`)。两者语义不同,别强行同步。
class AppInfo {
  AppInfo._();

  static const name = 'Dream Manga Reader';
  static const cnName = '梦漫';
  static const version = '1.0.0-beta.3';
  static const tagline = '跨平台漫画 + 番剧 · Android + Windows';
  static const author = 'TypeDreamMoon';
  static const repoUrl = 'https://github.com/TypeDreamMoon/DreamMangaReader';

  /// 用户可见的功能亮点(关于页展示)。
  static const highlights = <String>[
    '漫画 + 番剧:多源聚合、混合搜索 / 浏览',
    '番剧在线观看:HLS 播放器(libmpv)· 多源冗余',
    '瀑布流发现页 + 随机飞入动画',
    '详情页封面主题色(KMeans)+ Bangumi 评分',
    '离线下载 · 阅读进度记忆 · 阅读历史',
    '云同步:WebDAV / 账号登录(IAM 浏览器授权)· 可选类别双向合并',
    '源管理:zip 导入源 · GitHub 登录拉私有源仓',
    '书架备份 / 恢复 · 源可用性自检',
    '普通 / 日漫 / 滚动三种阅读模式',
    'OLED / Dark / Light 三套主题',
  ];
}
