import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/widgets.dart';

import 'app_locale.dart';

/// 界面文案表。**基类 = 简体中文(源语言,永远完整)**;其它语言子类只覆盖
/// 已翻译的条目,未译条目继承基类 → 优雅回退到简体(支持逐步补齐,见 [[translate]])。
///
/// 用法:`context.l10n.navBookshelf`。新增文案:在 [AppStrings] 加一个 getter(填简体),
/// 再到 [AppStringsEn]/[AppStringsJa]/[AppStringsZhHant] 各补一条译文即可。
///
/// 注:仅覆盖**面向用户的 UI**;运行日志 / 调试页 / 源脚本内文案保持中文(诊断用途)。
class AppStrings {
  const AppStrings();

  /// Localizations 委托:挂到 MaterialApp.localizationsDelegates。
  static const LocalizationsDelegate<AppStrings> delegate = _AppStringsDelegate();

  /// 便捷取用(委托已在 MaterialApp 注册,子树必有值)。
  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ?? const AppStrings();

  // ---- 底部导航 ----
  String get navBookshelf => '书架';
  String get navDiscover => '发现';
  String get navDownloads => '下载';
  String get navSettings => '设置';

  // ---- 通用按钮 / 动作 ----
  String get ok => '确定';
  String get cancel => '取消';
  String get retry => '重试';
  String get done => '完成';
  String get close => '关闭';
  String get later => '稍后';
  String get save => '保存';
  String get delete => '删除';
  String get confirm => '确认';
  String get goDownloadPage => '去下载页';
  String get loadFailed => '加载失败';

  // ---- 设置页:分组标题 ----
  String get settingsTitle => '设置';
  String get secAppearance => '外观';
  String get secDesktop => '桌面';
  String get secReading => '阅读';
  String get secBookshelf => '书架';
  String get secOther => '其它';

  // ---- 设置页:外观组 ----
  String get theme => '主题';
  String get controlRadius => '控件圆角';
  String get enableAnimations => '开启动画';
  String get enableAnimationsSub => '入场 / 页面切换 / 翻页等动画;关掉更省电、更跟手';
  String get scrollAnimations => '滚动动画';
  String get scrollAnimationsSub => '列表滚入淡入/滑入 + 桌面滚轮平滑滚动(受「开启动画」总开关约束)';
  String get language => '语言';
  String get languageSub => '界面显示语言(仅本机,不随云同步)';

  // ---- 设置页:桌面组 ----
  String get uiScale => '界面缩放';
  String get font => '字体';
  String get chooseFont => '选择字体';

  // ---- 设置页:关于 ----
  String get about => '关于';
}

/// English.
class AppStringsEn extends AppStrings {
  const AppStringsEn();

  @override String get navBookshelf => 'Library';
  @override String get navDiscover => 'Discover';
  @override String get navDownloads => 'Downloads';
  @override String get navSettings => 'Settings';

  @override String get ok => 'OK';
  @override String get cancel => 'Cancel';
  @override String get retry => 'Retry';
  @override String get done => 'Done';
  @override String get close => 'Close';
  @override String get later => 'Later';
  @override String get save => 'Save';
  @override String get delete => 'Delete';
  @override String get confirm => 'Confirm';
  @override String get goDownloadPage => 'Download page';
  @override String get loadFailed => 'Load failed';

  @override String get settingsTitle => 'Settings';
  @override String get secAppearance => 'Appearance';
  @override String get secDesktop => 'Desktop';
  @override String get secReading => 'Reading';
  @override String get secBookshelf => 'Library';
  @override String get secOther => 'Other';

  @override String get theme => 'Theme';
  @override String get controlRadius => 'Corner radius';
  @override String get enableAnimations => 'Animations';
  @override String get enableAnimationsSub =>
      'Entrance / page transitions / paging animations; off saves battery and feels snappier';
  @override String get scrollAnimations => 'Scroll animations';
  @override String get scrollAnimationsSub =>
      'List fade/slide-in + smooth desktop wheel scrolling (gated by the Animations switch)';
  @override String get language => 'Language';
  @override String get languageSub =>
      'UI display language (this device only, not synced)';

  @override String get uiScale => 'UI scale';
  @override String get font => 'Font';
  @override String get chooseFont => 'Choose font';

  @override String get about => 'About';
}

/// 日本語.
class AppStringsJa extends AppStrings {
  const AppStringsJa();

  @override String get navBookshelf => '本棚';
  @override String get navDiscover => '発見';
  @override String get navDownloads => 'ダウンロード';
  @override String get navSettings => '設定';

  @override String get ok => 'OK';
  @override String get cancel => 'キャンセル';
  @override String get retry => '再試行';
  @override String get done => '完了';
  @override String get close => '閉じる';
  @override String get later => '後で';
  @override String get save => '保存';
  @override String get delete => '削除';
  @override String get confirm => '確認';
  @override String get goDownloadPage => 'ダウンロードページ';
  @override String get loadFailed => '読み込み失敗';

  @override String get settingsTitle => '設定';
  @override String get secAppearance => '外観';
  @override String get secDesktop => 'デスクトップ';
  @override String get secReading => '読書';
  @override String get secBookshelf => '本棚';
  @override String get secOther => 'その他';

  @override String get theme => 'テーマ';
  @override String get controlRadius => '角の丸み';
  @override String get enableAnimations => 'アニメーション';
  @override String get enableAnimationsSub =>
      '登場 / 画面遷移 / ページめくりなどのアニメ。オフで省電力・軽快に';
  @override String get scrollAnimations => 'スクロールアニメ';
  @override String get scrollAnimationsSub =>
      'リストのフェード/スライドイン + デスクトップのスムーズホイール(「アニメーション」に従属)';
  @override String get language => '言語';
  @override String get languageSub => '表示言語(この端末のみ・同期しません)';

  @override String get uiScale => 'UIスケール';
  @override String get font => 'フォント';
  @override String get chooseFont => 'フォントを選択';

  @override String get about => '情報';
}

/// 繁體中文.
class AppStringsZhHant extends AppStrings {
  const AppStringsZhHant();

  @override String get navBookshelf => '書架';
  @override String get navDiscover => '發現';
  @override String get navDownloads => '下載';
  @override String get navSettings => '設定';

  @override String get ok => '確定';
  @override String get cancel => '取消';
  @override String get retry => '重試';
  @override String get done => '完成';
  @override String get close => '關閉';
  @override String get later => '稍後';
  @override String get save => '儲存';
  @override String get delete => '刪除';
  @override String get confirm => '確認';
  @override String get goDownloadPage => '前往下載頁';
  @override String get loadFailed => '載入失敗';

  @override String get settingsTitle => '設定';
  @override String get secAppearance => '外觀';
  @override String get secDesktop => '桌面';
  @override String get secReading => '閱讀';
  @override String get secBookshelf => '書架';
  @override String get secOther => '其它';

  @override String get theme => '主題';
  @override String get controlRadius => '控制項圓角';
  @override String get enableAnimations => '開啟動畫';
  @override String get enableAnimationsSub => '入場 / 頁面切換 / 翻頁等動畫;關掉更省電、更跟手';
  @override String get scrollAnimations => '捲動動畫';
  @override String get scrollAnimationsSub =>
      '清單捲入淡入/滑入 + 桌面滾輪平滑捲動(受「開啟動畫」總開關約束)';
  @override String get language => '語言';
  @override String get languageSub => '介面顯示語言(僅本機,不隨雲端同步)';

  @override String get uiScale => '介面縮放';
  @override String get font => '字型';
  @override String get chooseFont => '選擇字型';

  @override String get about => '關於';
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();

  @override
  bool isSupported(Locale locale) => AppLocale.fromLocale(locale) != null;

  @override
  Future<AppStrings> load(Locale locale) {
    final l = AppLocale.fromLocale(locale) ?? AppLocale.zhHans;
    final AppStrings s = switch (l) {
      AppLocale.zhHans => const AppStrings(),
      AppLocale.zhHant => const AppStringsZhHant(),
      AppLocale.ja => const AppStringsJa(),
      AppLocale.en => const AppStringsEn(),
    };
    return SynchronousFuture<AppStrings>(s);
  }

  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}

/// `context.l10n.xxx` 取当前语言文案。
extension AppStringsX on BuildContext {
  AppStrings get l10n => AppStrings.of(this);
}
