import 'dart:ui' show Locale;

/// App 支持的界面语言。**本机设置**(不随云同步),存 [code] 到 SharedPreferences。
enum AppLocale {
  // 简体 = 通用中文(不带 script),与 gen-l10n 的模板 locale `zh` 对齐;
  // 繁体是带 Hant 的变体。
  zhHans('zh', null, '简体中文'),
  zhHant('zh', 'Hant', '繁體中文'),
  ja('ja', null, '日本語'),
  en('en', null, 'English');

  const AppLocale(this.lang, this.script, this.label);

  /// ISO 语言码。
  final String lang;

  /// 文字变体(仅中文用 Hans/Hant 区分简繁),其它语言为空。
  final String? script;

  /// 语言自身的显示名(选择器里各语言用自己的写法,不翻译)。
  final String label;

  Locale toLocale() => script == null
      ? Locale(lang)
      : Locale.fromSubtags(languageCode: lang, scriptCode: script);

  /// 持久化用的稳定串:`zh_Hans` / `ja`。
  String get code => script == null ? lang : '${lang}_$script';

  /// 从持久化串还原;未知/空 → 简体中文(源语言,默认)。
  static AppLocale fromCode(String? c) {
    for (final v in values) {
      if (v.code == c) return v;
    }
    return zhHans;
  }

  /// 从系统/框架 [Locale] 匹配;中文按 scriptCode 区分简繁(缺省当简体)。
  /// 匹配不到返回 null(交给 MaterialApp 的 localeResolutionCallback / 默认回退)。
  static AppLocale? fromLocale(Locale l) {
    if (l.languageCode == 'ja') return ja;
    if (l.languageCode == 'en') return en;
    if (l.languageCode == 'zh') {
      final s = l.scriptCode ?? '';
      if (s == 'Hant' ||
          l.countryCode == 'TW' ||
          l.countryCode == 'HK' ||
          l.countryCode == 'MO') {
        return zhHant;
      }
      return zhHans;
    }
    return null;
  }
}
