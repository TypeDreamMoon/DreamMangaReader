import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读模式:paged=横向翻页(默认),webtoon=纵向连续滚动(条漫)。
/// 阅读模式:paged=普通横翻(左→右),pagedRtl=日漫横翻(右→左),webtoon=滚动竖读。
enum ReaderMode { paged, pagedRtl, webtoon }

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
  static const _kBangumiBindings = 'lib.bangumiBindings'; // 手动绑定的 bgm 条目

  final Map<String, FavoriteEntry> _favorites = {};
  final Map<String, ReadState> _history = {};
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
  final Map<String, int> _bangumiBindings = {}; // 'sid:mid' -> bgm subject id

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
  int? bangumiBindingFor(String key) => _bangumiBindings[key];

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
      _disabledSources
          .addAll(prefs.getStringList(_kDisabledSources) ?? const []);
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

  // ---- 备份 / 恢复 ----
  Map<String, dynamic> exportData() => {
        'v': 1,
        'favorites': [for (final e in _favorites.values) e.toJson()],
        'history': {for (final e in _history.entries) e.key: e.value.toJson()},
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
        'bangumiBindings': _bangumiBindings,
        'disabledSources': _disabledSources.toList(),
      };

  Future<void> importData(Map<String, dynamic> j) async {
    _favorites.clear();
    _history.clear();
    for (final f in (j['favorites'] as List? ?? const [])) {
      final e = FavoriteEntry.fromJson((f as Map).cast<String, dynamic>());
      _favorites[e.key] = e;
    }
    ((j['history'] as Map?) ?? const {}).forEach((k, v) {
      _history[k as String] =
          ReadState.fromJson((v as Map).cast<String, dynamic>());
    });
    _readerMode = ReaderMode.values.firstWhere(
        (m) => m.name == j['readerMode'], orElse: () => ReaderMode.paged);
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
    _persistFavorites();
    _persistHistoryNow();
    _prefs?.setString(_kReaderMode, switch (_readerMode) {
      ReaderMode.webtoon => 'webtoon',
      ReaderMode.pagedRtl => 'rtl',
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
    _prefs?.setString(_kBangumiBindings, jsonEncode(_bangumiBindings));
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
