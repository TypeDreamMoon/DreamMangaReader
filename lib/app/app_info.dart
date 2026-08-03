/// App 元信息(关于页 / 调试页共用)。
///
/// [version] = 用户可见的发布版本(含预发布后缀,与 git tag 对齐);
/// pubspec.yaml 的 `version:` 使用相同 SemVer，并追加 `+n` build number。
class AppInfo {
  AppInfo._();

  static const name = 'Dream Manga Reader';
  static const cnName = '梦漫';
  static const version = '1.4.0';
  static const tagline = '跨平台漫画 + 番剧 + 小说 · Android + Windows';
  static const author = 'TypeDreamMoon';
  static const repoUrl = 'https://github.com/TypeDreamMoon/DreamMangaReader';

  /// 用户可见的功能亮点(关于页展示)。
  static const highlights = <String>[
    '漫画 + 番剧 + 小说:多源聚合、混合搜索 / 浏览',
    '小说阅读器:滚动 / 分页 · 整书进度跳转 · 宽屏侧边目录 · 工具栏自动隐藏',
    '小说排版:字号行距页边距、阅读主题、屏幕常亮 · 键盘 / 滚轮 / 触摸翻页',
    '小说导入:本地 TXT(UTF-8 / GBK / Big5 自动识别)与可重排 EPUB',
    '番剧在线观看:HLS 播放器(libmpv)· 悬浮控制面板(选集/线路/倍速)',
    '哔哩哔哩番剧:扫码登录 · DASH 高清 · 追番 / 热门 · Bangumi 评分',
    '瀑布流发现页 + 随机飞入动画(漫画 / 小说共用布局与列数设置)',
    '详情页封面飞入 + 封面主题色(KMeans)+ Bangumi 评分',
    '长目录直达在读章 · 宽屏左信息右目录',
    '离线下载 · 阅读进度记忆 · 阅读历史',
    '云同步:WebDAV / 账号登录(IAM 浏览器授权)· 可选类别双向合并',
    '源管理:zip 导入源 · GitHub 登录拉私有源仓 · 刷新后脚本立即生效',
    '分页集合协议:超大章节表 / 图片集分批拉取',
    '书架备份 / 恢复 · 源可用性自检',
    '普通 / 日漫 / 竖翻 / 滚动 四种阅读模式 · 缩放适配 · 色彩滤镜',
    '每漫画模式记忆 + 高瘦条漫自动识别 · 条漫自动滚动 · 保存/分享页',
    'OLED / Dark / Light 三套主题',
  ];
}
