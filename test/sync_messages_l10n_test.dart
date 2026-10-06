import 'package:dream_manga_reader/core/l10n/app_strings.dart';
import 'package:dream_manga_reader/core/net/app_proxy.dart';
import 'package:dream_manga_reader/core/sync/sync_messages.dart';
import 'package:dream_manga_reader/features/settings/proxy_settings_page.dart';
import 'package:dream_manga_reader/features/settings/sync_messages.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 中日韩以外的界面里不该冒出汉字。用于证明「核心层不再往 UI 塞中文」。
final _han = RegExp(r'[一-鿿]');

Future<AppLocalizations> _l10n(Locale locale) =>
    AppLocalizations.delegate.load(locale);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const notices = <SyncNotice>[
    SyncNotice(SyncMessage.syncing),
    SyncNotice(SyncMessage.uploading),
    SyncNotice(SyncMessage.downloading),
    SyncNotice(SyncMessage.synced, favorites: 12, history: 34),
    SyncNotice(SyncMessage.uploaded, count: 3),
    SyncNotice(SyncMessage.downloaded, count: 2),
    SyncNotice(SyncMessage.serverEmpty),
    SyncNotice(SyncMessage.testWebDavReady),
    SyncNotice(SyncMessage.testAccountReady),
    SyncNotice(SyncMessage.notConfiguredAccount),
    SyncNotice(SyncMessage.notConfiguredWebDav),
    SyncNotice(SyncMessage.noCategoriesChosen),
    SyncNotice(SyncMessage.noDownloadChosen),
    SyncNotice(SyncMessage.alreadySyncing),
    SyncNotice(SyncMessage.uploadConflictRetries),
    SyncNotice(SyncMessage.notLoggedIn),
    SyncNotice(SyncMessage.sessionExpired),
    SyncNotice(SyncMessage.serviceOnlineNotLoggedIn),
    SyncNotice(SyncMessage.serviceDown, httpStatus: 503),
    SyncNotice(SyncMessage.authFailed, httpStatus: 401),
    SyncNotice(SyncMessage.forbidden, httpStatus: 403),
    SyncNotice(SyncMessage.pullFailed, httpStatus: 500),
    SyncNotice(SyncMessage.pushFailed, httpStatus: 500),
    SyncNotice(SyncMessage.unexpectedStatus, httpStatus: 418),
    SyncNotice(SyncMessage.unreachable, detail: 'SocketException'),
    SyncNotice(SyncMessage.autoSyncFailed, detail: 'SocketException'),
    SyncNotice(SyncMessage.autoUploadFailed, detail: 'SocketException'),
  ];

  test('每个同步消息码在四种语言下都有文案', () async {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = await _l10n(locale);
      for (final notice in notices) {
        final text = syncNoticeText(l10n, notice);
        expect(text.trim(), isNotEmpty,
            reason: '${locale.toLanguageTag()} 缺 ${notice.message.name}');
      }
    }
  });

  test('SyncMessage 的每个取值都被 UI 映射覆盖', () {
    final covered = {for (final n in notices) n.message};
    expect(covered, SyncMessage.values.toSet());
  });

  test('英文界面下同步文案里不再出现中文', () async {
    final l10n = await _l10n(const Locale('en'));
    for (final notice in notices) {
      final text = syncNoticeText(l10n, notice);
      expect(_han.hasMatch(text), isFalse,
          reason: '${notice.message.name} → $text');
    }
  });

  test('日文界面下也没有从核心层漏过来的中文串', () async {
    final l10n = await _l10n(const Locale('ja'));
    // 日文本身用汉字,这里只挑几条「核心层原来硬编码的中文」验证是真翻过的。
    expect(syncNoticeText(l10n, const SyncNotice(SyncMessage.syncing)),
        isNot('同步中…'));
    expect(syncNoticeText(l10n, const SyncNotice(SyncMessage.serverEmpty)),
        isNot('服务器暂无数据'));
  });

  test('数字/状态码进得了文案', () async {
    final l10n = await _l10n(const Locale('en'));
    expect(
        syncNoticeText(
            l10n, const SyncNotice(SyncMessage.synced, favorites: 12, history: 34)),
        allOf(contains('12'), contains('34')));
    expect(
        syncNoticeText(
            l10n, const SyncNotice(SyncMessage.authFailed, httpStatus: 401)),
        contains('401'));
  });

  test('SyncException 走同一套映射,别的异常兜底成「连不上」', () async {
    final l10n = await _l10n(const Locale('en'));
    expect(
      syncErrorText(l10n, SyncException.of(SyncMessage.sessionExpired)),
      syncNoticeText(l10n, const SyncNotice(SyncMessage.sessionExpired)),
    );
    expect(syncErrorText(l10n, StateError('boom')), contains('boom'));
  });

  test('代理来源在英文界面下也是英文(不再直接用日志常量)', () async {
    final l10n = await _l10n(const Locale('en'));
    for (final s in ProxySource.values) {
      final text = proxySourceText(l10n, s);
      expect(text.trim(), isNotEmpty);
      expect(_han.hasMatch(text), isFalse, reason: '$s → $text');
    }
    // 日志常量本身仍是中文——它只该出现在日志里。
    expect(_han.hasMatch(AppProxy.sourceLabel), isTrue);
  });
}
