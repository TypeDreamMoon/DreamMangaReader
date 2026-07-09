import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/source/chapter_number.dart';
import '../core/source/title_match.dart';
import '../core/translate/translator.dart' show TranslateProvider, LlmConfig;

/// 阅读模式:paged=横向翻页(默认),webtoon=纵向连续滚动(条漫)。
/// 阅读模式:paged=普通横翻(左→右),pagedRtl=日漫横翻(右→左),webtoon=滚动竖读。
enum ReaderMode { paged, pagedRtl, vertical, webtoon }

/// 阅读器底色预设(不显示全局背景图时)。dark=近黑(默认)。
enum ReaderBackground { dark, black, white, sepia }

/// 阅读器屏幕方向锁(仅移动端生效)。
enum ReaderOrientation { auto, portrait, landscape }

/// 单页缩放/适配模式(翻页模式;条漫恒为适宽)。
/// fitScreen=适应屏幕(默认),fitWidth=适应宽度(高图纵向滚动),
/// fitHeight=适应高度,original=原始像素。
enum ZoomMode { fitScreen, fitWidth, fitHeight, original }

/// 一本收藏。存足够渲染书架封面的信息(不依赖再次联网)。
class FavoriteEntry {
  FavoriteEntry({
    required this.sourceId,
    required this.mangaId,
    required this.title,
    this.cover,
    required this.addedAt,
  });

  final String sourceId;
  final String mangaId;
  final String title;
  final String? cover;
  final int addedAt; // epoch ms

  String get key => '$sourceId:$mangaId';

  Map<String, dynamic> toJson() =>
      {'s': sourceId, 'm': mangaId, 't': title, 'c': cover, 'a': addedAt};

  static FavoriteEntry fromJson(Map<String, dynamic> j) => FavoriteEntry(
        sourceId: j['s'] as String,
        mangaId: j['m'] as String,
        title: (j['t'] as String?) ?? '',
        cover: j['c'] as String?,
        addedAt: (j['a'] as num?)?.toInt() ?? 0,
      );
}

/// 单章阅读进度标记(章节列表打勾/进度用)。
class ChapterMark {
  const ChapterMark(this.page, this.total);
  final int page; // 读到第几页(0 基)
  final int total; // 总页数(0=未知)
  bool get finished => total > 0 && page >= total - 1;
}

/// 一本书的阅读态:最近读到哪 + 每章进度。供「继续阅读」和章节标记用。
class ReadState {
  ReadState({
    required this.sourceId,
    required this.mangaId,
    required this.title,
    this.cover,
    required this.lastChapterId,
    required this.lastChapterName,
    required this.lastPage,
    required this.lastTotal,
    required this.updatedAt,
    required this.chapters,
  });

  final String sourceId;
  final String mangaId;
  final String title;
  final String? cover;
  String lastChapterId;
  String lastChapterName;
  int lastPage;
  int lastTotal;
  int updatedAt; // epoch ms
  final Map<String, ChapterMark> chapters; // chapterId -> mark

  String get key => '$sourceId:$mangaId';

  Map<String, dynamic> toJson() => {
        's': sourceId,
        'm': mangaId,
        't': title,
        'c': cover,
        'lc': lastChapterId,
        'ln': lastChapterName,
        'lp': lastPage,
        'lt': lastTotal,
        'u': updatedAt,
        'ch': {
          for (final e in chapters.entries) e.key: [e.value.page, e.value.total]
        },
      };

  static ReadState fromJson(Map<String, dynamic> j) {
    final ch = <String, ChapterMark>{};
    final raw = (j['ch'] as Map?) ?? const {};
    raw.forEach((k, v) {
      final l = (v as List?) ?? const [0, 0];
      ch[k as String] = ChapterMark(
          (l.isNotEmpty ? l[0] as num : 0).toInt(),
          (l.length > 1 ? l[1] as num : 0).toInt());
    });
    return ReadState(
      sourceId: j['s'] as String,
      mangaId: j['m'] as String,
      title: (j['t'] as String?) ?? '',
      cover: j['c'] as String?,
      lastChapterId: (j['lc'] as String?) ?? '',
      lastChapterName: (j['ln'] as String?) ?? '',
      lastPage: (j['lp'] as num?)?.toInt() ?? 0,
      lastTotal: (j['lt'] as num?)?.toInt() ?? 0,
      updatedAt: (j['u'] as num?)?.toInt() ?? 0,
      chapters: ch,
    );
  }
}

/// 「作品」级共享进度:同名书(跨源)共用一份续读点 + 已读章集合,按**话数**对齐。
/// key = normalizeTitle(标题)。只到章节级(页码不跨源共享);续读点 = 最后读到的位置。
class WorkProgress {
  WorkProgress({
    required this.chapterNumber,
    required this.chapterLabel,
    required this.updatedAt,
    required this.lastSourceId,
    Set<double>? readChapters,
  }) : readChapters = readChapters ?? <double>{};

  double chapterNumber; // 续读点话数(最后读到的那话)
  String chapterLabel; // 该话章名(展示用)
  int updatedAt; // epoch ms
  String lastSourceId; // 最后在哪个源读的
  final Set<double> readChapters; // 已读章的话数集合(跨源打勾 / 合并表)

  Map<String, dynamic> toJson() => {
        'n': chapterNumber,
        'l': chapterLabel,
        'u': updatedAt,
        's': lastSourceId,
        'r': readChapters.toList(),
      };

  static WorkProgress fromJson(Map<String, dynamic> j) => WorkProgress(
        chapterNumber: (j['n'] as num?)?.toDouble() ?? 0,
        chapterLabel: (j['l'] as String?) ?? '',
        updatedAt: (j['u'] as num?)?.toInt() ?? 0,
        lastSourceId: (j['s'] as String?) ?? '',
        readChapters: {
          for (final x in (j['r'] as List? ?? const []))
            if (x is num) x.toDouble()
        },
      );
}

/// 书架的本地持久层:收藏、阅读进度/历史、阅读模式。
///
/// 沿用 App 既有的 ChangeNotifier + InheritedNotifier(ThemeScope/SourceScope)模式:
/// 页面 `LibraryScope.of(context)` 读写,notify 时依赖它的页面自动重建。
/// 落盘走 SharedPreferences(Android + Windows 都支持,JSON 编码结构化数据)。
class LibraryStore extends ChangeNotifier {
  static const _kFavorites = 'lib.favorites';
  static const _kHistory = 'lib.history';
  static const _kReaderMode = 'lib.readerMode';
  static const _kGridColumns = 'lib.gridColumns';
  static const _kPreload = 'lib.preload';
  static const _kDoublePage = 'lib.doublePage';
  static const _kDoubleTapZoom = 'lib.doubleTapZoom';
  static const _kShowPageNumber = 'lib.showPageNumber';
  static const _kBrightness = 'lib.brightness';
  static const _kWebtoonWidth = 'lib.webtoonWidth'; // 条漫横屏内容宽度占比
  static const _kCoverRadius = 'lib.coverRadius';
  static const _kControlRadius = 'lib.controlRadius';
  static const _kBgImage = 'lib.bgImage';
  static const _kBgBlur = 'lib.bgBlur';
  static const _kBgTintColor = 'lib.bgTintColor';
  static const _kBgTintAlpha = 'lib.bgTintAlpha';
  static const _kReaderBackground = 'lib.readerBackground';
  static const _kEnableAnimations = 'lib.enableAnimations';
  static const _kScrollAnimations = 'lib.scrollAnimations'; // 滚动动画(滚入+平滑滚轮)
  static const _kAutoCheckUpdate = 'lib.autoCheckUpdate'; // 启动自动检查更新
  static const _kUpdateIncludeBeta = 'lib.updateIncludeBeta'; // 检查更新含测试版
  static const _kUiScale = 'lib.uiScale'; // 桌面:界面文字缩放
  static const _kUiFont = 'lib.uiFont'; // 桌面:字体族(空=跟随回退栈)
  static const _kDisabledSources = 'lib.disabledSources';
  static const _kDetailTintStrength = 'lib.detailTintStrength'; // 详情页封面色融合强度
  static const _kReaderGestures = 'lib.readerGestures'; // 阅读器点击分区翻页
  static const _kReaderGestureHintSeen = 'lib.readerGestureHintSeen'; // 手势提示已看过
  static const _kVolumeKeyPaging = 'lib.volumeKeyPaging'; // Android 音量键翻页
  static const _kInvertTapZones = 'lib.invertTapZones'; // 反转左右点击翻页方向
  static const _kReaderBg = 'lib.readerBg'; // 阅读器底色预设
  static const _kReaderOrientation = 'lib.readerOrientation'; // 阅读器方向锁
  static const _kKeepScreenOn = 'lib.keepScreenOn'; // 阅读时常亮屏幕
  static const _kAutoDetectMode = 'lib.autoDetectMode'; // 自动判断条漫(高瘦图)
  static const _kMangaModes = 'lib.mangaModes'; // 每本漫画的阅读模式覆盖
  static const _kWebtoonGap = 'lib.webtoonGap'; // 条漫页间距
  static const _kChapterToast = 'lib.chapterToast'; // 跨章提示新章名
  static const _kCfGrayscale = 'lib.cfGrayscale'; // 滤镜:黑白
  static const _kCfInvert = 'lib.cfInvert'; // 滤镜:反色
  static const _kCfSepia = 'lib.cfSepia'; // 滤镜:护眼纸色
  static const _kCfContrast = 'lib.cfContrast'; // 滤镜:对比度
  static const _kZoomMode = 'lib.zoomMode'; // 单页缩放/适配模式
  static const _kAutoScrollSpeed = 'lib.autoScrollSpeed'; // 条漫自动滚动速度 px/s
  static const _kBangumiBindings = 'lib.bangumiBindings'; // 手动绑定的 bgm 条目
  static const _kSearchHistory = 'lib.searchHistory'; // 漫画搜索历史(可随设置同步)
  static const _maxSearchHistory = 30; // 搜索历史上限(超出丢最旧)
  static const _kTranslateProvider = 'lib.translateProvider'; // 搜索翻译服务商
  static const _kTranslateLlmBase = 'lib.translateLlmBase'; // 大模型 API 地址
  static const _kTranslateLlmKey = 'lib.translateLlmKey'; // 大模型 API 密钥(本机,不同步)
  static const _kTranslateLlmModel = 'lib.translateLlmModel'; // 大模型模型名
  static const _kWorkProgress = 'lib.workProgress'; // 作品级共享进度(跨源同名)

  final Map<String, FavoriteEntry> _favorites = {};
  final Map<String, ReadState> _history = {};
  // 作品级共享进度:key = normalizeTitle(标题)。同名书跨源共用续读点 + 已读章集合。
  final Map<String, WorkProgress> _workProgress = {};
  final Set<String> _disabledSources = {};
  ReaderMode _readerMode = ReaderMode.paged;
  int _gridColumns = 0; // 0 = 自适应
  int _preload = 3; // 预加载后 N 页
  bool _doublePage = false; // 翻页模式双页并排
  bool _doubleTapZoom = true; // 允许双击缩放
  bool _showPageNumber = true; // 展示页码
  double _brightness = 1.0; // 阅读器亮度(0.25~1.0,靠遮罩变暗)
  double _webtoonWidth = 0.5; // 条漫横屏内容宽度占屏比(0.3~1.0,越小图越小=一屏看更多)
  double _coverRadius = 12; // 封面圆角(0~24)
  // 控件统一圆角。用 ValueNotifier 单独广播:它驱动全局 ThemeData 重建,
  // 不能挂在高频的 notifyListeners 上(阅读时 markProgress 每 ~400ms 通知一次)。
  final ValueNotifier<double> controlRadiusVN = ValueNotifier(14);
  // 桌面缩放 / 字体也走 VN 广播:改动只需重建 ThemeData / 顶层 MediaQuery。
  final ValueNotifier<double> uiScaleVN = ValueNotifier(1.0);
  final ValueNotifier<String> uiFontVN = ValueNotifier('');
  String _bgImage = ''; // 全局背景图路径(空=无)
  double _bgBlur = 12; // 背景模糊(0~40)
  int _bgTintColor = 0xFF000000; // 背景混合色(RGB,alpha 见 _bgTintAlpha)
  double _bgTintAlpha = 0.45; // 混合色强度(0~1)
  bool _readerBackground = false; // 阅读器是否也显示全局背景
  bool _enableAnimations = true; // 全局动画开关
  bool _scrollAnimations = true; // 列表滚动动画:滚入淡入/滑入 + 桌面滚轮平滑滚动
  bool _autoCheckUpdate = true; // 启动时自动检查更新
  bool _updateIncludeBeta = false; // 检查更新是否含测试版(-beta/-rc)
  double _detailTintStrength = 0.55; // 详情页封面色融合强度(0=纯底色/黑,1=纯封面色)
  bool _readerGestures = true; // 阅读器左右点击翻页
  bool _readerGestureHintSeen = false; // 首次进入阅读器的手势提示是否已展示
  bool _volumeKeyPaging = false; // Android 音量键翻页
  bool _invertTapZones = false; // 反转左右点击翻页方向(左=下一页)
  ReaderBackground _readerBg = ReaderBackground.dark; // 阅读器底色预设
  ReaderOrientation _readerOrientation = ReaderOrientation.auto; // 方向锁
  bool _keepScreenOn = true; // 阅读时常亮屏幕
  bool _autoDetectMode = true; // 自动判断条漫(高瘦图 → 滚动模式)
  final Map<String, String> _mangaModes = {}; // 'sid:mid' -> ReaderMode.name
  double _webtoonGap = 0; // 条漫页间距 px(0~40)
  bool _chapterToast = true; // 跨章时提示新章名
  bool _cfGrayscale = false; // 滤镜:黑白
  bool _cfInvert = false; // 滤镜:反色(暗色漫 / 夜读)
  bool _cfSepia = false; // 滤镜:护眼纸色
  double _cfContrast = 1.0; // 滤镜:对比度(0.5~1.5,1=正常)
  ZoomMode _zoomMode = ZoomMode.fitScreen; // 单页缩放/适配模式
  double _autoScrollSpeed = 40; // 条漫自动滚动速度 px/s(10~200)
  final Map<String, int> _bangumiBindings = {}; // 'sid:mid' -> bgm subject id
  final List<String> _searchHistory = []; // 漫画搜索历史(最近在前)
  TranslateProvider _translateProvider = TranslateProvider.google; // 搜索翻译服务商
  String _translateLlmBase = ''; // 大模型 API 地址(OpenAI 兼容)
  String _translateLlmKey = ''; // 大模型 API 密钥(仅本机)
  String _translateLlmModel = ''; // 大模型模型名

  /// 全局动画开关的**同步镜像**:动画组件常在 initState/字段初始化处拿不到 context,
  /// 直接读这个静态量。只由 load()/setter/importData 写。
  static bool animationsEnabled = true;

  /// 滚动动画的同步镜像(= 开启动画 **且** 滚动动画)。列表滚入/平滑滚轮直接读它。
  static bool scrollAnimationsEnabled = true;

  bool _loaded = false;

  SharedPreferences? _prefs;
  Timer? _persistHistoryTimer;
  Timer? _notifyTimer;
  bool _disposed = false;

  bool get loaded => _loaded;
  ReaderMode get readerMode => _readerMode;
  int get gridColumns => _gridColumns; // 0 = 自适应
  int get preload => _preload;
  bool get doublePage => _doublePage;
  bool get doubleTapZoom => _doubleTapZoom;
  bool get showPageNumber => _showPageNumber;
  double get brightness => _brightness;
  double get webtoonWidth => _webtoonWidth;
  double get coverRadius => _coverRadius;
  double get controlRadius => controlRadiusVN.value;
  double get uiScale => uiScaleVN.value; // 桌面界面文字缩放(1.0=100%)
  String get uiFont => uiFontVN.value; // 桌面字体族('' = 系统默认回退栈)
  String get bgImage => _bgImage;
  double get bgBlur => _bgBlur;
  int get bgTintColor => _bgTintColor;
  double get bgTintAlpha => _bgTintAlpha;
  bool get readerBackground => _readerBackground;
  bool get enableAnimations => _enableAnimations;
  bool get scrollAnimations => _scrollAnimations;
  bool get autoCheckUpdate => _autoCheckUpdate;
  bool get updateIncludeBeta => _updateIncludeBeta;
  double get detailTintStrength => _detailTintStrength;
  bool get readerGestures => _readerGestures;
  bool get readerGestureHintSeen => _readerGestureHintSeen;
  bool get volumeKeyPaging => _volumeKeyPaging;
  bool get invertTapZones => _invertTapZones;
  ReaderBackground get readerBg => _readerBg;
  ReaderOrientation get readerOrientation => _readerOrientation;
  bool get keepScreenOn => _keepScreenOn;
  bool get autoDetectMode => _autoDetectMode;
  String? mangaMode(String key) => _mangaModes[key];
  double get webtoonGap => _webtoonGap;
  bool get chapterToast => _chapterToast;
  bool get cfGrayscale => _cfGrayscale;
  bool get cfInvert => _cfInvert;
  bool get cfSepia => _cfSepia;
  double get cfContrast => _cfContrast;
  ZoomMode get zoomMode => _zoomMode;
  double get autoScrollSpeed => _autoScrollSpeed;
  int? bangumiBindingFor(String key) => _bangumiBindings[key];

  /// 漫画搜索历史(最近搜的在前)。
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  /// 记一条搜索历史:去空白、大小写不敏感去重后置顶,超上限丢最旧。
  void addSearchHistory(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    _searchHistory.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    _searchHistory.insert(0, q);
    if (_searchHistory.length > _maxSearchHistory) {
      _searchHistory.removeRange(_maxSearchHistory, _searchHistory.length);
    }
    _persistSearchHistory();
    notifyListeners();
  }

  void removeSearchHistory(String query) {
    if (_searchHistory.remove(query)) {
      _persistSearchHistory();
      notifyListeners();
    }
  }

  void clearSearchHistory() {
    if (_searchHistory.isEmpty) return;
    _searchHistory.clear();
    _persistSearchHistory();
    notifyListeners();
  }

  void _persistSearchHistory() =>
      _prefs?.setStringList(_kSearchHistory, _searchHistory);

  // ---- 搜索翻译 ----
  TranslateProvider get translateProvider => _translateProvider;
  String get translateLlmBase => _translateLlmBase;
  String get translateLlmKey => _translateLlmKey;
  String get translateLlmModel => _translateLlmModel;

  /// 大模型翻译配置(供 Translator.create 用)。
  LlmConfig get translateLlm => LlmConfig(
        baseUrl: _translateLlmBase,
        apiKey: _translateLlmKey,
        model: _translateLlmModel,
      );

  set translateProvider(TranslateProvider v) {
    if (v == _translateProvider) return;
    _translateProvider = v;
    _prefs?.setString(_kTranslateProvider, v.name);
    notifyListeners();
  }

  set translateLlmBase(String v) {
    if (v == _translateLlmBase) return;
    _translateLlmBase = v;
    _prefs?.setString(_kTranslateLlmBase, v);
    notifyListeners();
  }

  set translateLlmKey(String v) {
    if (v == _translateLlmKey) return;
    _translateLlmKey = v;
    _prefs?.setString(_kTranslateLlmKey, v);
    notifyListeners();
  }

  set translateLlmModel(String v) {
    if (v == _translateLlmModel) return;
    _translateLlmModel = v;
    _prefs?.setString(_kTranslateLlmModel, v);
    notifyListeners();
  }

  bool isSourceEnabled(String id) => !_disabledSources.contains(id);

  /// 启用/禁用一个源(至少保留一个启用)。[total] 为已注册源总数。
  void setSourceEnabled(String id, bool enabled, int total) {
    if (enabled) {
      _disabledSources.remove(id);
    } else {
      if (total - _disabledSources.length <= 1) return; // 别禁到一个不剩
      _disabledSources.add(id);
    }
    _prefs?.setStringList(_kDisabledSources, _disabledSources.toList());
    notifyListeners();
  }

  /// 收藏列表(最近收藏在前)。
  List<FavoriteEntry> get favorites {
    final l = _favorites.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return l;
  }

  /// 阅读历史(最近读的在前)。
  List<ReadState> get history {
    final l = _history.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l;
  }

  bool isFavorite(String sourceId, String mangaId) =>
      _favorites.containsKey('$sourceId:$mangaId');

  ChapterMark? chapterMark(String sourceId, String mangaId, String chapterId) =>
      _history['$sourceId:$mangaId']?.chapters[chapterId];

  ReadState? readState(String sourceId, String mangaId) =>
      _history['$sourceId:$mangaId'];

  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    try {
      final favRaw = prefs.getString(_kFavorites);
      if (favRaw != null) {
        for (final j in (jsonDecode(favRaw) as List)) {
          final e = FavoriteEntry.fromJson((j as Map).cast<String, dynamic>());
          _favorites[e.key] = e;
        }
      }
      final hRaw = prefs.getString(_kHistory);
      if (hRaw != null) {
        (jsonDecode(hRaw) as Map).forEach((k, v) {
          _history[k as String] =
              ReadState.fromJson((v as Map).cast<String, dynamic>());
        });
      }
      final mode = prefs.getString(_kReaderMode);
      _readerMode = switch (mode) {
        'webtoon' => ReaderMode.webtoon,
        'rtl' => ReaderMode.pagedRtl,
        'vertical' => ReaderMode.vertical,
        _ => ReaderMode.paged,
      };
      _gridColumns = (prefs.getInt(_kGridColumns) ?? 0).clamp(0, 8);
      _preload = (prefs.getInt(_kPreload) ?? 3).clamp(0, 10);
      _doublePage = prefs.getBool(_kDoublePage) ?? false;
      _doubleTapZoom = prefs.getBool(_kDoubleTapZoom) ?? true;
      _showPageNumber = prefs.getBool(_kShowPageNumber) ?? true;
      _brightness = (prefs.getDouble(_kBrightness) ?? 1.0).clamp(0.25, 1.0);
      _webtoonWidth = (prefs.getDouble(_kWebtoonWidth) ?? 0.5).clamp(0.3, 1.0);
      _coverRadius = (prefs.getDouble(_kCoverRadius) ?? 12).clamp(0, 24);
      controlRadiusVN.value = (prefs.getDouble(_kControlRadius) ?? 14).clamp(0, 28);
      uiScaleVN.value = (prefs.getDouble(_kUiScale) ?? 1.0).clamp(0.7, 1.6);
      uiFontVN.value = prefs.getString(_kUiFont) ?? '';
      _bgImage = prefs.getString(_kBgImage) ?? '';
      _bgBlur = (prefs.getDouble(_kBgBlur) ?? 12).clamp(0, 40);
      _bgTintColor = prefs.getInt(_kBgTintColor) ?? 0xFF000000;
      _bgTintAlpha = (prefs.getDouble(_kBgTintAlpha) ?? 0.45).clamp(0, 1);
      _readerBackground = prefs.getBool(_kReaderBackground) ?? false;
      _enableAnimations = prefs.getBool(_kEnableAnimations) ?? true;
      animationsEnabled = _enableAnimations;
      _scrollAnimations = prefs.getBool(_kScrollAnimations) ?? true;
      scrollAnimationsEnabled = _enableAnimations && _scrollAnimations;
      _autoCheckUpdate = prefs.getBool(_kAutoCheckUpdate) ?? true;
      _updateIncludeBeta = prefs.getBool(_kUpdateIncludeBeta) ?? false;
      _detailTintStrength =
          (prefs.getDouble(_kDetailTintStrength) ?? 0.55).clamp(0, 1);
      _readerGestures = prefs.getBool(_kReaderGestures) ?? true;
      _readerGestureHintSeen = prefs.getBool(_kReaderGestureHintSeen) ?? false;
      _volumeKeyPaging = prefs.getBool(_kVolumeKeyPaging) ?? false;
      _invertTapZones = prefs.getBool(_kInvertTapZones) ?? false;
      _readerBg = ReaderBackground.values.firstWhere(
          (b) => b.name == prefs.getString(_kReaderBg),
          orElse: () => ReaderBackground.dark);
      _readerOrientation = ReaderOrientation.values.firstWhere(
          (o) => o.name == prefs.getString(_kReaderOrientation),
          orElse: () => ReaderOrientation.auto);
      _keepScreenOn = prefs.getBool(_kKeepScreenOn) ?? true;
      _autoDetectMode = prefs.getBool(_kAutoDetectMode) ?? true;
      _webtoonGap = (prefs.getDouble(_kWebtoonGap) ?? 0).clamp(0, 40);
      _chapterToast = prefs.getBool(_kChapterToast) ?? true;
      _cfGrayscale = prefs.getBool(_kCfGrayscale) ?? false;
      _cfInvert = prefs.getBool(_kCfInvert) ?? false;
      _cfSepia = prefs.getBool(_kCfSepia) ?? false;
      _cfContrast = (prefs.getDouble(_kCfContrast) ?? 1.0).clamp(0.5, 1.5);
      _zoomMode = ZoomMode.values.firstWhere(
          (z) => z.name == prefs.getString(_kZoomMode),
          orElse: () => ZoomMode.fitScreen);
      _autoScrollSpeed =
          (prefs.getDouble(_kAutoScrollSpeed) ?? 40).clamp(10, 200);
      // 单独 try:损坏的绑定 JSON 不能连累后面 _disabledSources 等的加载。
      final bgmRaw = prefs.getString(_kBangumiBindings);
      if (bgmRaw != null) {
        try {
          final m = jsonDecode(bgmRaw);
          if (m is Map) {
            m.forEach((k, v) {
              final id = (v as num?)?.toInt();
              if (id != null) _bangumiBindings[k as String] = id;
            });
          }
        } catch (_) {}
      }
      final mmRaw = prefs.getString(_kMangaModes);
      if (mmRaw != null) {
        try {
          final m = jsonDecode(mmRaw);
          if (m is Map) {
            m.forEach((k, v) {
              if (v is String) _mangaModes[k as String] = v;
            });
          }
        } catch (_) {}
      }
      _disabledSources
          .addAll(prefs.getStringList(_kDisabledSources) ?? const []);
      final sh = prefs.getStringList(_kSearchHistory);
      if (sh != null) {
        _searchHistory.addAll(sh.take(_maxSearchHistory));
      }
      _translateProvider = TranslateProvider.values.firstWhere(
          (e) => e.name == prefs.getString(_kTranslateProvider),
          orElse: () => TranslateProvider.google);
      _translateLlmBase = prefs.getString(_kTranslateLlmBase) ?? '';
      _translateLlmKey = prefs.getString(_kTranslateLlmKey) ?? '';
      _translateLlmModel = prefs.getString(_kTranslateLlmModel) ?? '';
      final wpRaw = prefs.getString(_kWorkProgress);
      if (wpRaw != null) {
        try {
          final m = jsonDecode(wpRaw);
          if (m is Map) {
            m.forEach((k, v) {
              if (v is Map) {
                _workProgress[k as String] =
                    WorkProgress.fromJson(v.cast<String, dynamic>());
              }
            });
          }
        } catch (_) {}
      }
    } catch (_) {
      // 损坏的存档不致命:当作空的继续。
    }
    _loaded = true;
    notifyListeners();
  }

  set readerMode(ReaderMode v) {
    if (v == _readerMode) return;
    _readerMode = v;
    _prefs?.setString(
        _kReaderMode,
        switch (v) {
          ReaderMode.webtoon => 'webtoon',
          ReaderMode.pagedRtl => 'rtl',
          ReaderMode.vertical => 'vertical',
          ReaderMode.paged => 'paged',
        });
    notifyListeners(); // 用户动作,低频,即时通知
  }

  set doublePage(bool v) {
    if (v == _doublePage) return;
    _doublePage = v;
    _prefs?.setBool(_kDoublePage, v);
    notifyListeners();
  }

  set doubleTapZoom(bool v) {
    if (v == _doubleTapZoom) return;
    _doubleTapZoom = v;
    _prefs?.setBool(_kDoubleTapZoom, v);
    notifyListeners();
  }

  set showPageNumber(bool v) {
    if (v == _showPageNumber) return;
    _showPageNumber = v;
    _prefs?.setBool(_kShowPageNumber, v);
    notifyListeners();
  }

  set brightness(double v) {
    v = v.clamp(0.25, 1.0);
    if (v == _brightness) return;
    _brightness = v;
    _prefs?.setDouble(_kBrightness, v);
    notifyListeners();
  }

  set webtoonWidth(double v) {
    v = v.clamp(0.3, 1.0);
    if (v == _webtoonWidth) return;
    _webtoonWidth = v;
    _prefs?.setDouble(_kWebtoonWidth, v);
    notifyListeners();
  }

  set coverRadius(double v) {
    v = v.clamp(0, 24);
    if (v == _coverRadius) return;
    _coverRadius = v;
    _prefs?.setDouble(_kCoverRadius, v);
    notifyListeners();
  }

  set controlRadius(double v) {
    v = v.clamp(0, 28);
    if (v == controlRadiusVN.value) return;
    controlRadiusVN.value = v; // 广播给全局 ThemeData 重建
    _prefs?.setDouble(_kControlRadius, v);
    notifyListeners(); // 让设置页滑块本身刷新
  }

  set uiScale(double v) {
    v = v.clamp(0.7, 1.6);
    if (v == uiScaleVN.value) return;
    uiScaleVN.value = v;
    _prefs?.setDouble(_kUiScale, v);
    notifyListeners();
  }

  set uiFont(String v) {
    if (v == uiFontVN.value) return;
    uiFontVN.value = v;
    _prefs?.setString(_kUiFont, v);
    notifyListeners();
  }

  set bgImage(String v) {
    if (v == _bgImage) return;
    _bgImage = v;
    _prefs?.setString(_kBgImage, v);
    notifyListeners();
  }

  set bgBlur(double v) {
    v = v.clamp(0, 40);
    if (v == _bgBlur) return;
    _bgBlur = v;
    _prefs?.setDouble(_kBgBlur, v);
    notifyListeners();
  }

  set bgTintColor(int v) {
    if (v == _bgTintColor) return;
    _bgTintColor = v;
    _prefs?.setInt(_kBgTintColor, v);
    notifyListeners();
  }

  set bgTintAlpha(double v) {
    v = v.clamp(0, 1);
    if (v == _bgTintAlpha) return;
    _bgTintAlpha = v;
    _prefs?.setDouble(_kBgTintAlpha, v);
    notifyListeners();
  }

  set readerBackground(bool v) {
    if (v == _readerBackground) return;
    _readerBackground = v;
    _prefs?.setBool(_kReaderBackground, v);
    notifyListeners();
  }

  set enableAnimations(bool v) {
    if (v == _enableAnimations) return;
    _enableAnimations = v;
    animationsEnabled = v;
    scrollAnimationsEnabled = _enableAnimations && _scrollAnimations;
    _prefs?.setBool(_kEnableAnimations, v);
    notifyListeners();
  }

  set scrollAnimations(bool v) {
    if (v == _scrollAnimations) return;
    _scrollAnimations = v;
    scrollAnimationsEnabled = _enableAnimations && _scrollAnimations;
    _prefs?.setBool(_kScrollAnimations, v);
    notifyListeners();
  }

  set autoCheckUpdate(bool v) {
    if (v == _autoCheckUpdate) return;
    _autoCheckUpdate = v;
    _prefs?.setBool(_kAutoCheckUpdate, v);
    notifyListeners();
  }

  set updateIncludeBeta(bool v) {
    if (v == _updateIncludeBeta) return;
    _updateIncludeBeta = v;
    _prefs?.setBool(_kUpdateIncludeBeta, v);
    notifyListeners();
  }

  set detailTintStrength(double v) {
    v = v.clamp(0, 1);
    if (v == _detailTintStrength) return;
    _detailTintStrength = v;
    _prefs?.setDouble(_kDetailTintStrength, v);
    notifyListeners();
  }

  set readerGestures(bool v) {
    if (v == _readerGestures) return;
    _readerGestures = v;
    _prefs?.setBool(_kReaderGestures, v);
    notifyListeners();
  }

  set volumeKeyPaging(bool v) {
    if (v == _volumeKeyPaging) return;
    _volumeKeyPaging = v;
    _prefs?.setBool(_kVolumeKeyPaging, v);
    notifyListeners();
  }

  set invertTapZones(bool v) {
    if (v == _invertTapZones) return;
    _invertTapZones = v;
    _prefs?.setBool(_kInvertTapZones, v);
    notifyListeners();
  }

  set readerBg(ReaderBackground v) {
    if (v == _readerBg) return;
    _readerBg = v;
    _prefs?.setString(_kReaderBg, v.name);
    notifyListeners();
  }

  set readerOrientation(ReaderOrientation v) {
    if (v == _readerOrientation) return;
    _readerOrientation = v;
    _prefs?.setString(_kReaderOrientation, v.name);
    notifyListeners();
  }

  set keepScreenOn(bool v) {
    if (v == _keepScreenOn) return;
    _keepScreenOn = v;
    _prefs?.setBool(_kKeepScreenOn, v);
    notifyListeners();
  }

  set autoDetectMode(bool v) {
    if (v == _autoDetectMode) return;
    _autoDetectMode = v;
    _prefs?.setBool(_kAutoDetectMode, v);
    notifyListeners();
  }

  set webtoonGap(double v) {
    v = v.clamp(0, 40);
    if (v == _webtoonGap) return;
    _webtoonGap = v;
    _prefs?.setDouble(_kWebtoonGap, v);
    notifyListeners();
  }

  set chapterToast(bool v) {
    if (v == _chapterToast) return;
    _chapterToast = v;
    _prefs?.setBool(_kChapterToast, v);
    notifyListeners();
  }

  set cfGrayscale(bool v) {
    if (v == _cfGrayscale) return;
    _cfGrayscale = v;
    _prefs?.setBool(_kCfGrayscale, v);
    notifyListeners();
  }

  set cfInvert(bool v) {
    if (v == _cfInvert) return;
    _cfInvert = v;
    _prefs?.setBool(_kCfInvert, v);
    notifyListeners();
  }

  set cfSepia(bool v) {
    if (v == _cfSepia) return;
    _cfSepia = v;
    _prefs?.setBool(_kCfSepia, v);
    notifyListeners();
  }

  set cfContrast(double v) {
    v = v.clamp(0.5, 1.5);
    if (v == _cfContrast) return;
    _cfContrast = v;
    _prefs?.setDouble(_kCfContrast, v);
    notifyListeners();
  }

  set zoomMode(ZoomMode v) {
    if (v == _zoomMode) return;
    _zoomMode = v;
    _prefs?.setString(_kZoomMode, v.name);
    notifyListeners();
  }

  set autoScrollSpeed(double v) {
    v = v.clamp(10, 200);
    if (v == _autoScrollSpeed) return;
    _autoScrollSpeed = v;
    _prefs?.setDouble(_kAutoScrollSpeed, v);
    notifyListeners();
  }

  /// 覆盖某本漫画的阅读模式(null=清除覆盖,回退全局默认)。
  void setMangaMode(String key, ReaderMode? mode) {
    final name = mode?.name;
    if (name == null) {
      if (_mangaModes.remove(key) == null) return;
    } else {
      if (_mangaModes[key] == name) return;
      _mangaModes[key] = name;
    }
    _prefs?.setString(_kMangaModes, jsonEncode(_mangaModes));
    notifyListeners();
  }

  // 一次性标记:不 notify(无需重建 UI)。
  set readerGestureHintSeen(bool v) {
    if (v == _readerGestureHintSeen) return;
    _readerGestureHintSeen = v;
    _prefs?.setBool(_kReaderGestureHintSeen, v);
  }

  /// 手动把某本漫画绑定到指定 bgm 条目(null=解绑)。
  void setBangumiBinding(String key, int? subjectId) {
    if (subjectId == null) {
      if (_bangumiBindings.remove(key) == null) return;
    } else {
      if (_bangumiBindings[key] == subjectId) return;
      _bangumiBindings[key] = subjectId;
    }
    _prefs?.setString(_kBangumiBindings, jsonEncode(_bangumiBindings));
    notifyListeners();
  }

  set gridColumns(int v) {
    v = v.clamp(0, 8);
    if (v == _gridColumns) return;
    _gridColumns = v;
    _prefs?.setInt(_kGridColumns, v);
    notifyListeners();
  }

  set preload(int v) {
    v = v.clamp(0, 10);
    if (v == _preload) return;
    _preload = v;
    _prefs?.setInt(_kPreload, v);
    notifyListeners();
  }

  void toggleFavorite(FavoriteEntry e) {
    if (_favorites.remove(e.key) == null) _favorites[e.key] = e;
    _persistFavorites();
    notifyListeners(); // 用户动作,低频,即时通知
  }

  /// 记录/更新阅读进度。reader 每次翻页调用。
  void markProgress({
    required String sourceId,
    required String mangaId,
    required String title,
    String? cover,
    required String chapterId,
    required String chapterName,
    required int page,
    required int total,
    required int nowMs,
  }) {
    final key = '$sourceId:$mangaId';
    final st = _history[key] ??
        ReadState(
          sourceId: sourceId,
          mangaId: mangaId,
          title: title,
          cover: cover,
          lastChapterId: chapterId,
          lastChapterName: chapterName,
          lastPage: page,
          lastTotal: total,
          updatedAt: nowMs,
          chapters: {},
        );
    st.lastChapterId = chapterId;
    st.lastChapterName = chapterName;
    st.lastPage = page;
    st.lastTotal = total;
    st.updatedAt = nowMs;
    // 每章保留“读到最远处”。
    final prev = st.chapters[chapterId];
    if (prev == null || page > prev.page || total > prev.total) {
      st.chapters[chapterId] = ChapterMark(page, total);
    }
    _history[key] = st;
    _schedulePersistHistory();
    // 逐页推进高频:内存已即时更新,**通知防抖**——把滚动风暴合并成每 ~400ms 一次,
    // 停手/退出后自然刷新一次。避免每翻一页就全量重建后台书架/详情(LibraryScope.of 依赖者),
    // 也避免在 reader.dispose 锁定期同步 notify(会报 framework locked)。
    _scheduleNotify();
  }

  // 防抖通知(高频进度更新用)。
  void _scheduleNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 400), () {
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _prefs?.remove(_kHistory);
    notifyListeners();
  }

  void removeHistory(String sourceId, String mangaId) {
    if (_history.remove('$sourceId:$mangaId') != null) {
      _persistHistoryNow();
      notifyListeners();
    }
  }

  // ---- 作品级共享进度(跨源同名) ----

  /// 取某作品的共享进度(按归一标题);无则 null。
  WorkProgress? workProgressFor(String title) =>
      _workProgress[normalizeTitle(title)];

  /// 某作品所有已读章的话数集合(跨源打勾用);无则空集。
  Set<double> readChaptersFor(String title) =>
      _workProgress[normalizeTitle(title)]?.readChapters ?? const {};

  /// 记录/推进作品共享进度:[chapterName] 解析出话数 → 更新续读点(最后读到的那话)
  /// 并把该话计入已读集合。解析不出话数(番外/序章等)则忽略,不参与跨源对齐。
  void recordWork({
    required String title,
    required String chapterName,
    required String sourceId,
    required int nowMs,
  }) {
    final key = normalizeTitle(title);
    if (key.isEmpty) return;
    final num = parseChapterNumber(chapterName);
    if (num == null) return;
    final wp = _workProgress[key];
    if (wp == null) {
      _workProgress[key] = WorkProgress(
        chapterNumber: num,
        chapterLabel: chapterName,
        updatedAt: nowMs,
        lastSourceId: sourceId,
        readChapters: {num},
      );
    } else {
      wp.readChapters.add(num);
      // 续读点 = 最后读到的位置(与单源「继续阅读」语义一致),不取最远。
      wp.chapterNumber = num;
      wp.chapterLabel = chapterName;
      wp.updatedAt = nowMs;
      wp.lastSourceId = sourceId;
    }
    _persistWorkProgress();
  }

  void _persistWorkProgress() => _prefs?.setString(_kWorkProgress,
      jsonEncode({for (final e in _workProgress.entries) e.key: e.value.toJson()}));

  // ---- 备份 / 恢复 ----
  Map<String, dynamic> exportData() => {
        'v': 1,
        'favorites': [for (final e in _favorites.values) e.toJson()],
        'history': {for (final e in _history.entries) e.key: e.value.toJson()},
        'workProgress': {
          for (final e in _workProgress.entries) e.key: e.value.toJson()
        },
        'readerMode': _readerMode.name,
        'gridColumns': _gridColumns,
        'preload': _preload,
        'doublePage': _doublePage,
        'doubleTapZoom': _doubleTapZoom,
        'showPageNumber': _showPageNumber,
        'brightness': _brightness,
        'webtoonWidth': _webtoonWidth,
        'coverRadius': _coverRadius,
        'controlRadius': controlRadiusVN.value,
        'uiScale': uiScaleVN.value,
        'uiFont': uiFontVN.value,
        'bgImage': _bgImage,
        'bgBlur': _bgBlur,
        'bgTintColor': _bgTintColor,
        'bgTintAlpha': _bgTintAlpha,
        'readerBackground': _readerBackground,
        'enableAnimations': _enableAnimations,
        'scrollAnimations': _scrollAnimations,
        'autoCheckUpdate': _autoCheckUpdate,
        'updateIncludeBeta': _updateIncludeBeta,
        'detailTintStrength': _detailTintStrength,
        'readerGestures': _readerGestures,
        'volumeKeyPaging': _volumeKeyPaging,
        'invertTapZones': _invertTapZones,
        'readerBg': _readerBg.name,
        'readerOrientation': _readerOrientation.name,
        'keepScreenOn': _keepScreenOn,
        'autoDetectMode': _autoDetectMode,
        'webtoonGap': _webtoonGap,
        'chapterToast': _chapterToast,
        'cfGrayscale': _cfGrayscale,
        'cfInvert': _cfInvert,
        'cfSepia': _cfSepia,
        'cfContrast': _cfContrast,
        'zoomMode': _zoomMode.name,
        'autoScrollSpeed': _autoScrollSpeed,
        'mangaModes': _mangaModes,
        'bangumiBindings': _bangumiBindings,
        'searchHistory': _searchHistory.toList(),
        'translateProvider': _translateProvider.name,
        'translateLlmBase': _translateLlmBase,
        'translateLlmModel': _translateLlmModel,
        // 大模型 API 密钥属敏感数据,仅存本机,不导出/不同步(同源登录 token 同策略)。
        'disabledSources': _disabledSources.toList(),
      };

  /// 应用一份(可能是部分的)备份/同步数据。
  ///
  /// [replaceFavorites]/[replaceHistory] 为 false 时**跳过**收藏/历史(既不清空也不覆盖),
  /// 供选择性同步只应用部分类别用。其余设置类键「缺省即保留」(j 里没有就保持当前值)。
  Future<void> importData(
    Map<String, dynamic> j, {
    bool replaceFavorites = true,
    bool replaceHistory = true,
  }) async {
    if (replaceFavorites) {
      _favorites.clear();
      for (final f in (j['favorites'] as List? ?? const [])) {
        final e = FavoriteEntry.fromJson((f as Map).cast<String, dynamic>());
        _favorites[e.key] = e;
      }
    }
    if (replaceHistory) {
      _history.clear();
      ((j['history'] as Map?) ?? const {}).forEach((k, v) {
        _history[k as String] =
            ReadState.fromJson((v as Map).cast<String, dynamic>());
      });
    }
    // 作品级共享进度随「历史/进度」类别走。只有 j 里带了才动(旧备份没有 → 不误清)。
    if (replaceHistory && j.containsKey('workProgress')) {
      _workProgress.clear();
      ((j['workProgress'] as Map?) ?? const {}).forEach((k, v) {
        if (v is Map) {
          _workProgress[k as String] =
              WorkProgress.fromJson(v.cast<String, dynamic>());
        }
      });
    }
    _readerMode = ReaderMode.values.firstWhere(
        (m) => m.name == j['readerMode'], orElse: () => _readerMode);
    _gridColumns = (j['gridColumns'] as num?)?.toInt() ?? _gridColumns;
    _preload = (j['preload'] as num?)?.toInt() ?? _preload;
    _doublePage = j['doublePage'] as bool? ?? _doublePage;
    _doubleTapZoom = j['doubleTapZoom'] as bool? ?? _doubleTapZoom;
    _showPageNumber = j['showPageNumber'] as bool? ?? _showPageNumber;
    _brightness = (j['brightness'] as num?)?.toDouble() ?? _brightness;
    _webtoonWidth =
        ((j['webtoonWidth'] as num?)?.toDouble() ?? _webtoonWidth).clamp(0.3, 1.0);
    _coverRadius = (j['coverRadius'] as num?)?.toDouble() ?? _coverRadius;
    controlRadiusVN.value =
        (j['controlRadius'] as num?)?.toDouble() ?? controlRadiusVN.value;
    uiScaleVN.value = (j['uiScale'] as num?)?.toDouble() ?? uiScaleVN.value;
    uiFontVN.value = j['uiFont'] as String? ?? uiFontVN.value;
    _bgImage = j['bgImage'] as String? ?? _bgImage;
    _bgBlur = (j['bgBlur'] as num?)?.toDouble() ?? _bgBlur;
    _bgTintColor = (j['bgTintColor'] as num?)?.toInt() ?? _bgTintColor;
    _bgTintAlpha = (j['bgTintAlpha'] as num?)?.toDouble() ?? _bgTintAlpha;
    _readerBackground = j['readerBackground'] as bool? ?? _readerBackground;
    _enableAnimations = j['enableAnimations'] as bool? ?? _enableAnimations;
    animationsEnabled = _enableAnimations;
    _scrollAnimations = j['scrollAnimations'] as bool? ?? _scrollAnimations;
    scrollAnimationsEnabled = _enableAnimations && _scrollAnimations;
    _autoCheckUpdate = j['autoCheckUpdate'] as bool? ?? _autoCheckUpdate;
    _updateIncludeBeta = j['updateIncludeBeta'] as bool? ?? _updateIncludeBeta;
    _detailTintStrength =
        (j['detailTintStrength'] as num?)?.toDouble() ?? _detailTintStrength;
    _readerGestures = j['readerGestures'] as bool? ?? _readerGestures;
    _volumeKeyPaging = j['volumeKeyPaging'] as bool? ?? _volumeKeyPaging;
    _invertTapZones = j['invertTapZones'] as bool? ?? _invertTapZones;
    _readerBg = ReaderBackground.values
        .firstWhere((b) => b.name == j['readerBg'], orElse: () => _readerBg);
    _readerOrientation = ReaderOrientation.values.firstWhere(
        (o) => o.name == j['readerOrientation'],
        orElse: () => _readerOrientation);
    _keepScreenOn = j['keepScreenOn'] as bool? ?? _keepScreenOn;
    _autoDetectMode = j['autoDetectMode'] as bool? ?? _autoDetectMode;
    _webtoonGap =
        ((j['webtoonGap'] as num?)?.toDouble() ?? _webtoonGap).clamp(0, 40);
    _chapterToast = j['chapterToast'] as bool? ?? _chapterToast;
    _cfGrayscale = j['cfGrayscale'] as bool? ?? _cfGrayscale;
    _cfInvert = j['cfInvert'] as bool? ?? _cfInvert;
    _cfSepia = j['cfSepia'] as bool? ?? _cfSepia;
    _cfContrast =
        ((j['cfContrast'] as num?)?.toDouble() ?? _cfContrast).clamp(0.5, 1.5);
    _zoomMode = ZoomMode.values
        .firstWhere((z) => z.name == j['zoomMode'], orElse: () => _zoomMode);
    _autoScrollSpeed =
        ((j['autoScrollSpeed'] as num?)?.toDouble() ?? _autoScrollSpeed)
            .clamp(10, 200);
    final mm = j['mangaModes'] as Map?;
    if (mm != null) {
      _mangaModes.clear();
      mm.forEach((k, v) {
        if (v is String) _mangaModes[k as String] = v;
      });
    }
    final disabled = j['disabledSources'] as List?;
    if (disabled != null) {
      _disabledSources
        ..clear()
        ..addAll(disabled.map((e) => e.toString()));
      _prefs?.setStringList(_kDisabledSources, _disabledSources.toList());
    }
    final bgmBind = j['bangumiBindings'] as Map?;
    if (bgmBind != null) {
      _bangumiBindings.clear();
      bgmBind.forEach((k, v) {
        final id = (v as num?)?.toInt();
        if (id != null) _bangumiBindings[k as String] = id;
      });
    }
    final sh = j['searchHistory'] as List?;
    if (sh != null) {
      // 外部/远程 blob 可能含空白或大小写重复项 → 按与 addSearchHistory 相同的
      // 不变式清洗(去空白、大小写不敏感去重、截断),别把脏数据渲染成重复/空白词条。
      _searchHistory.clear();
      final seen = <String>{};
      for (final e in sh) {
        final t = e.toString().trim();
        if (t.isEmpty || !seen.add(t.toLowerCase())) continue;
        _searchHistory.add(t);
        if (_searchHistory.length >= _maxSearchHistory) break;
      }
      _persistSearchHistory();
    }
    _translateProvider = TranslateProvider.values.firstWhere(
        (e) => e.name == j['translateProvider'],
        orElse: () => _translateProvider);
    _translateLlmBase = j['translateLlmBase'] as String? ?? _translateLlmBase;
    _translateLlmModel = j['translateLlmModel'] as String? ?? _translateLlmModel;
    if (replaceFavorites) _persistFavorites();
    if (replaceHistory) _persistHistoryNow();
    if (replaceHistory && j.containsKey('workProgress')) _persistWorkProgress();
    _prefs?.setString(_kReaderMode, switch (_readerMode) {
      ReaderMode.webtoon => 'webtoon',
      ReaderMode.pagedRtl => 'rtl',
      ReaderMode.vertical => 'vertical',
      ReaderMode.paged => 'paged',
    });
    _prefs?.setInt(_kGridColumns, _gridColumns);
    _prefs?.setInt(_kPreload, _preload);
    _prefs?.setBool(_kDoublePage, _doublePage);
    _prefs?.setBool(_kDoubleTapZoom, _doubleTapZoom);
    _prefs?.setBool(_kShowPageNumber, _showPageNumber);
    _prefs?.setDouble(_kBrightness, _brightness);
    _prefs?.setDouble(_kWebtoonWidth, _webtoonWidth);
    _prefs?.setDouble(_kCoverRadius, _coverRadius);
    _prefs?.setDouble(_kControlRadius, controlRadiusVN.value);
    _prefs?.setDouble(_kUiScale, uiScaleVN.value);
    _prefs?.setString(_kUiFont, uiFontVN.value);
    _prefs?.setString(_kBgImage, _bgImage);
    _prefs?.setDouble(_kBgBlur, _bgBlur);
    _prefs?.setInt(_kBgTintColor, _bgTintColor);
    _prefs?.setDouble(_kBgTintAlpha, _bgTintAlpha);
    _prefs?.setBool(_kReaderBackground, _readerBackground);
    _prefs?.setBool(_kEnableAnimations, _enableAnimations);
    _prefs?.setBool(_kScrollAnimations, _scrollAnimations);
    _prefs?.setBool(_kAutoCheckUpdate, _autoCheckUpdate);
    _prefs?.setBool(_kUpdateIncludeBeta, _updateIncludeBeta);
    _prefs?.setDouble(_kDetailTintStrength, _detailTintStrength);
    _prefs?.setBool(_kReaderGestures, _readerGestures);
    _prefs?.setBool(_kVolumeKeyPaging, _volumeKeyPaging);
    _prefs?.setBool(_kInvertTapZones, _invertTapZones);
    _prefs?.setString(_kReaderBg, _readerBg.name);
    _prefs?.setString(_kReaderOrientation, _readerOrientation.name);
    _prefs?.setBool(_kKeepScreenOn, _keepScreenOn);
    _prefs?.setBool(_kAutoDetectMode, _autoDetectMode);
    _prefs?.setDouble(_kWebtoonGap, _webtoonGap);
    _prefs?.setBool(_kChapterToast, _chapterToast);
    _prefs?.setBool(_kCfGrayscale, _cfGrayscale);
    _prefs?.setBool(_kCfInvert, _cfInvert);
    _prefs?.setBool(_kCfSepia, _cfSepia);
    _prefs?.setDouble(_kCfContrast, _cfContrast);
    _prefs?.setString(_kZoomMode, _zoomMode.name);
    _prefs?.setDouble(_kAutoScrollSpeed, _autoScrollSpeed);
    _prefs?.setString(_kMangaModes, jsonEncode(_mangaModes));
    _prefs?.setString(_kBangumiBindings, jsonEncode(_bangumiBindings));
    _prefs?.setString(_kTranslateProvider, _translateProvider.name);
    _prefs?.setString(_kTranslateLlmBase, _translateLlmBase);
    _prefs?.setString(_kTranslateLlmModel, _translateLlmModel);
    notifyListeners();
  }

  void _persistFavorites() {
    _prefs?.setString(_kFavorites,
        jsonEncode([for (final e in _favorites.values) e.toJson()]));
  }

  // 翻页频繁,防抖落盘(内存态已即时更新,掉电最多丢最后 <1s 的进度)。
  void _schedulePersistHistory() {
    _persistHistoryTimer?.cancel();
    _persistHistoryTimer =
        Timer(const Duration(milliseconds: 600), _persistHistoryNow);
  }

  void _persistHistoryNow() {
    _prefs?.setString(_kHistory,
        jsonEncode({for (final e in _history.entries) e.key: e.value.toJson()}));
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _persistHistoryTimer?.cancel();
    _persistHistoryNow(); // 退出前落盘最后进度
    super.dispose();
  }
}

/// 把 [LibraryStore] 下发到 widget 树,页面用 `LibraryScope.of(context)` 读写。
class LibraryScope extends InheritedNotifier<LibraryStore> {
  const LibraryScope({
    super.key,
    required LibraryStore store,
    required super.child,
  }) : super(notifier: store);

  static LibraryStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LibraryScope>();
    assert(scope != null, 'LibraryScope not found in context');
    return scope!.notifier!;
  }

  /// 只读取、**不注册依赖**——阅读器频繁写进度会触发 notify,不能让自己因此重建。
  static LibraryStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<LibraryScope>();
    assert(scope != null, 'LibraryScope not found in context');
    return scope!.notifier!;
  }
}
