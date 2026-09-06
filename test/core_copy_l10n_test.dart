import 'package:dream_manga_reader/core/l10n/app_strings.dart';
import 'package:dream_manga_reader/core/source/source_health.dart';
import 'package:dream_manga_reader/core/source/source_repository.dart';
import 'package:dream_manga_reader/core/translate/translator.dart';
import 'package:dream_manga_reader/features/settings/source_messages.dart';
import 'package:dream_manga_reader/features/settings/translate_messages.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 英文界面里不该出现汉字。
final _han = RegExp(r'[一-鿿]');

Future<AppLocalizations> _l10n(Locale locale) =>
    AppLocalizations.delegate.load(locale);

SourceHealthResult _result(
  SourceHealthStatus status, {
  int? count,
  int withCover = 0,
  List<String> samples = const [],
  String? errorDetail,
  SourceHealthFailure? failure,
  String? discoveryFn = 'getDiscovery',
  bool experimental = false,
}) =>
    SourceHealthResult(
      status,
      report: SourceHealthReport(
        sourceName: 'Demo',
        sourceId: 'demo',
        transport: SourceTransport.webView,
        experimental: experimental,
        timeoutSeconds: 25,
        discoveryFn: discoveryFn,
        elapsedMs: 812,
        count: count,
        withCover: withCover,
        samples: samples,
        errorDetail: errorDetail,
      ),
      elapsedMs: 812,
      count: count,
      failure: failure,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('翻译错误码', () {
    const errors = <TranslateException>[
      TranslateException(TranslateErrorCode.llmNotConfigured,
          provider: TranslateProvider.llm),
      TranslateException(TranslateErrorCode.noProvider),
      TranslateException(TranslateErrorCode.connectFailed,
          provider: TranslateProvider.google),
      TranslateException(TranslateErrorCode.timeout,
          provider: TranslateProvider.google),
      TranslateException(TranslateErrorCode.requestError,
          provider: TranslateProvider.google, detail: 'badCertificate'),
      TranslateException(TranslateErrorCode.badResponse,
          provider: TranslateProvider.microsoft),
      TranslateException(TranslateErrorCode.httpError,
          provider: TranslateProvider.microsoft, status: 429),
      TranslateException(TranslateErrorCode.emptyResult,
          provider: TranslateProvider.llm),
      TranslateException(TranslateErrorCode.tokenFailed,
          provider: TranslateProvider.microsoft, status: 502),
      TranslateException(TranslateErrorCode.failed),
    ];

    test('每个码在四种语言下都有文案', () async {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = await _l10n(locale);
        for (final e in errors) {
          expect(translateErrorText(l10n, e).trim(), isNotEmpty,
              reason: '${locale.toLanguageTag()} 缺 ${e.code.name}');
        }
      }
    });

    test('覆盖了 TranslateErrorCode 的全部取值', () {
      expect({for (final e in errors) e.code}, TranslateErrorCode.values.toSet());
    });

    test('英文界面下翻译报错不再是中文', () async {
      final l10n = await _l10n(const Locale('en'));
      for (final e in errors) {
        final text = translateErrorText(l10n, e);
        expect(_han.hasMatch(text), isFalse, reason: '${e.code.name} → $text');
      }
    });

    test('服务商名与状态码进得了文案', () async {
      final l10n = await _l10n(const Locale('en'));
      final text = translateErrorText(
          l10n,
          const TranslateException(TranslateErrorCode.httpError,
              provider: TranslateProvider.microsoft, status: 429));
      expect(text, contains('429'));
      expect(text,
          contains(translateProviderName(l10n, TranslateProvider.microsoft)));
    });

    test('服务商枚举不再自带中文 label(靠 l10n 映射)', () async {
      final en = await _l10n(const Locale('en'));
      for (final p in TranslateProvider.values) {
        final name = translateProviderName(en, p);
        expect(name.trim(), isNotEmpty);
        expect(_han.hasMatch(name), isFalse, reason: '$p → $name');
      }
    });
  });

  group('源检测日志', () {
    test('成功的日志在英文界面下没有中文', () async {
      final l10n = await _l10n(const Locale('en'));
      final text = sourceHealthLogText(
        l10n,
        _result(SourceHealthStatus.ok,
            count: 6, withCover: 2, samples: const ['Alpha', 'Beta']),
      );
      expect(_han.hasMatch(text), isFalse, reason: text);
      expect(text, contains('demo'));
      expect(text, contains('getDiscovery'));
      expect(text, contains('812'));
      expect(text, contains('Alpha'));
    });

    test('空结果与失败结果也走 l10n', () async {
      final l10n = await _l10n(const Locale('en'));
      expect(
          _han.hasMatch(
              sourceHealthLogText(l10n, _result(SourceHealthStatus.empty, count: 0))),
          isFalse);
      final fail = sourceHealthLogText(
        l10n,
        _result(SourceHealthStatus.fail,
            errorDetail: 'TimeoutException after 25s',
            failure: SourceHealthFailure.other),
      );
      // 底层异常文本是原样透传的诊断信息,不翻译;其余部分必须是英文。
      expect(fail, contains('TimeoutException'));
      expect(_han.hasMatch(fail.replaceAll('TimeoutException after 25s', '')),
          isFalse);
    });

    test('脚本卡死会多给一句「重试没用」的解释', () async {
      final l10n = await _l10n(const Locale('en'));
      final stuck = sourceHealthLogText(
        l10n,
        _result(SourceHealthStatus.fail,
            errorDetail: 'JsExecutionOverrun',
            failure: SourceHealthFailure.scriptStuck),
      );
      final plain = sourceHealthLogText(
        l10n,
        _result(SourceHealthStatus.fail,
            errorDetail: 'JsExecutionOverrun',
            failure: SourceHealthFailure.other),
      );
      expect(stuck.length, greaterThan(plain.length));
    });

    test('没测过时给一句「未检测」,不崩', () async {
      final l10n = await _l10n(const Locale('en'));
      expect(sourceHealthLogText(l10n, SourceHealthResult.unknown).trim(),
          isNotEmpty);
      expect(sourceHealthLogText(l10n, SourceHealthResult.checking).trim(),
          isNotEmpty);
    });

    test('实验性标记也是翻过的', () async {
      final l10n = await _l10n(const Locale('en'));
      final text = sourceHealthLogText(
          l10n, _result(SourceHealthStatus.ok, count: 1, experimental: true));
      expect(text, contains(l10n.srcmgmt_logExperimental));
      expect(_han.hasMatch(text), isFalse);
    });
  });

  group('源仓库状态', () {
    const statuses = <SourceRepoStatus>[
      SourceRepoStatus(SourceRepoOrigin.notLoaded),
      SourceRepoStatus(SourceRepoOrigin.notConfigured),
      SourceRepoStatus(SourceRepoOrigin.remote, repoCount: 7),
      SourceRepoStatus(SourceRepoOrigin.localDir, repoCount: 3),
      SourceRepoStatus(SourceRepoOrigin.cache, repoCount: 5, hiddenCount: 2),
      SourceRepoStatus(SourceRepoOrigin.devDir, repoCount: 1, localCount: 2),
      SourceRepoStatus(SourceRepoOrigin.cacheAfterFailure, repoCount: 4),
      SourceRepoStatus(SourceRepoOrigin.failed, error: 'SocketException'),
    ];

    test('每种来源在四种语言下都有文案', () async {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = await _l10n(locale);
        for (final s in statuses) {
          expect(sourceRepoStatusText(l10n, s).trim(), isNotEmpty,
              reason: '${locale.toLanguageTag()} 缺 ${s.origin.name}');
        }
      }
    });

    test('覆盖了 SourceRepoOrigin 的全部取值', () {
      expect({for (final s in statuses) s.origin},
          SourceRepoOrigin.values.toSet());
    });

    test('英文界面下不再显示中文状态串', () async {
      final l10n = await _l10n(const Locale('en'));
      for (final s in statuses) {
        final text = sourceRepoStatusText(l10n, s);
        expect(_han.hasMatch(text), isFalse, reason: '${s.origin.name} → $text');
      }
    });

    test('本地源 / 隐藏数量会拼进去', () async {
      final l10n = await _l10n(const Locale('en'));
      final text = sourceRepoStatusText(
        l10n,
        const SourceRepoStatus(SourceRepoOrigin.remote,
            repoCount: 7, localCount: 2, hiddenCount: 3),
      );
      expect(text, allOf(contains('7'), contains('2'), contains('3')));
    });

    test('debugText 仍是中文——它只给日志用', () {
      const s = SourceRepoStatus(SourceRepoOrigin.remote, repoCount: 7);
      expect(_han.hasMatch(s.debugText), isTrue);
      expect(s.isFailure, isFalse);
      expect(
          const SourceRepoStatus(SourceRepoOrigin.failed).isFailure, isTrue);
    });
  });
}
