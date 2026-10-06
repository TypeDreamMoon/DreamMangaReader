import '../../core/l10n/app_strings.dart';
import '../../core/translate/translator.dart';

/// 翻译服务商 → 当前语言的名字。
String translateProviderName(AppLocalizations l10n, TranslateProvider p) =>
    switch (p) {
      TranslateProvider.google => l10n.trans_provGoogle,
      TranslateProvider.microsoft => l10n.trans_provMicrosoft,
      TranslateProvider.llm => l10n.trans_provLlm,
    };

/// 翻译失败的错误码 → 当前语言文案。
///
/// 核心层的 [TranslateException] 只带码,翻译在这里做——发现页的搜索翻译、
/// 设置页的「测试」都用它,英/日界面才不会弹中文。
String translateErrorText(AppLocalizations l10n, Object error) {
  if (error is! TranslateException) return '$error';
  final provider = error.provider;
  final name = provider == null
      ? l10n.trans_title
      : translateProviderName(l10n, provider);
  final status = error.status ?? 0;
  return switch (error.code) {
    TranslateErrorCode.llmNotConfigured => l10n.trans_errLlmNotConfigured,
    TranslateErrorCode.noProvider => l10n.trans_errNoProvider,
    TranslateErrorCode.connectFailed => l10n.trans_errConnectFailed,
    TranslateErrorCode.timeout => l10n.trans_errTimeout,
    TranslateErrorCode.requestError =>
      l10n.trans_errRequest(error.detail ?? ''),
    TranslateErrorCode.badResponse => l10n.trans_errBadResponse,
    TranslateErrorCode.httpError => l10n.trans_errHttp(name, status),
    TranslateErrorCode.emptyResult => l10n.trans_errEmptyResult(name),
    TranslateErrorCode.tokenFailed => l10n.trans_errToken(name, status),
    TranslateErrorCode.failed => l10n.trans_errFailed,
  };
}
