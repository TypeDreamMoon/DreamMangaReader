import 'package:dream_manga_reader/app/auth_store.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/core/source/auth_token.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:dream_manga_reader/features/settings/account_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SecretStore {
  _MemorySecretStore([Map<String, String>? values])
      : values = Map<String, String>.of(values ?? const {});

  final Map<String, String> values;

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

const _picacg = SourceMeta(
  id: 'picacg',
  name: '哔咔',
  script: 'picacg',
  needsLogin: true,
);
const _xiaojieManga = SourceMeta(
  id: 'xiaojie_manga',
  name: '晓桀漫画',
  script: 'manga',
  needsLogin: true,
  authKey: 'xiaojie_github',
);
const _xiaojieNovel = SourceMeta(
  id: 'xiaojie_novel',
  name: '晓桀小说',
  script: 'novel',
  kind: 'novel',
  needsLogin: true,
  authKey: 'xiaojie_github',
);
const _open = SourceMeta(id: 'open', name: '免登录源', script: 'open');

Widget _host(AuthStore auth) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [AppTokens(palette: AppPalette.dark)]),
      home: AuthScope(store: auth, child: const AccountPage()),
    );

void main() {
  final original = List<SourceMeta>.of(registeredSources);

  tearDown(() {
    for (final source in registeredSources) {
      SourceAuth.set(source.id, null);
    }
    registeredSources = List<SourceMeta>.of(original);
  });

  testWidgets('账号页把 App 账号和所有源账号列在一起', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    registeredSources = <SourceMeta>[
      kBiliSourceMeta,
      _picacg,
      _xiaojieManga,
      _xiaojieNovel,
      _open,
    ];
    final auth = AuthStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: _MemorySecretStore(),
    );
    await auth.load();

    await tester.pumpWidget(_host(auth));
    await tester.pump();

    expect(find.text('梦漫账号'), findsOneWidget);
    expect(find.text('源账号'), findsOneWidget);
    expect(find.text('哔哩哔哩'), findsOneWidget);
    expect(find.text('哔咔'), findsOneWidget);
    // 共用凭据的两个晓桀源合成一行,拿组里第一个的名字。
    expect(find.text('晓桀漫画'), findsOneWidget);
    expect(find.text('晓桀小说'), findsNothing);
    expect(find.text('2 个源共用这份登录'), findsOneWidget);
    // 不需要登录的源不该出现。
    expect(find.text('免登录源'), findsNothing);
  });

  testWidgets('扫码源给扫码入口,账密源给登录入口', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    registeredSources = <SourceMeta>[kBiliSourceMeta, _picacg];
    final auth = AuthStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: _MemorySecretStore(),
    );
    await auth.load();

    await tester.pumpWidget(_host(auth));
    await tester.pump();

    expect(find.text('扫码登录'), findsOneWidget);
    // 「登录」既是梦漫账号的按钮也是哔咔的按钮。
    expect(find.text('登录'), findsNWidgets(2));
  });

  testWidgets('已登录的源显示账号名和退出', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth.picacg.username': 'reader',
      'auth.picacg.nickname': '读者',
    });
    registeredSources = <SourceMeta>[_picacg];
    final auth = AuthStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: _MemorySecretStore({'source.auth.picacg': 'token'}),
    );
    await auth.load();

    await tester.pumpWidget(_host(auth));
    await tester.pump();

    expect(find.text('读者'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
  });

  testWidgets('一个需要登录的源都没有时给空态', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    registeredSources = <SourceMeta>[_open];
    final auth = AuthStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: _MemorySecretStore(),
    );
    await auth.load();

    await tester.pumpWidget(_host(auth));
    await tester.pump();

    expect(find.text('当前没有需要登录的源'), findsOneWidget);
  });
}
