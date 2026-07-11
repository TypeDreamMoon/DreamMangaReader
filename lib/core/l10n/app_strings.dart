import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

export '../../l10n/app_localizations.dart';

/// `context.l10n.xxx` 取当前语言文案。
///
/// 文案表在 `lib/l10n/app_*.arb`(每语言一个,Kotatsu 的 strings.xml 之 Flutter 版);
/// `flutter gen-l10n` 据此生成类型安全的 [AppLocalizations](见 l10n.yaml)。
/// 加/改文案:编辑 arb → 构建时自动重新生成,**不写进 Dart、可挂 Weblate 众包**。
extension AppStringsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
