import 'package:dream_manga_reader/app/auth_store.dart';
import 'package:dream_manga_reader/core/source/auth_token.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:dream_manga_reader/features/settings/source_account.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = List<SourceMeta>.of(registeredSources);

  setUp(() {
    registeredSources = <SourceMeta>[
      kBiliSourceMeta,
      _picacg,
      _xiaojieManga,
      _xiaojieNovel,
      _open,
    ];
  });

  tearDown(() {
    for (final source in registeredSources) {
      SourceAuth.set(source.id, null);
    }
    registeredSources = List<SourceMeta>.of(original);
  });

  test('共用一份凭据的源在账号列表里只占一行', () {
    final accounts = sourceAccounts();

    // 晓桀漫画 + 晓桀小说 共用 xiaojie_github,应当合成一条。
    expect(accounts.map((a) => a.id),
        [kBiliSourceId, 'picacg', 'xiaojie_github']);
    final xiaojie = accounts.last;
    expect(xiaojie.isShared, isTrue);
    expect(xiaojie.sources.map((s) => s.id),
        ['xiaojie_manga', 'xiaojie_novel']);
  });

  test('不需要登录的源不进账号列表', () {
    expect(sourceAccounts().map((a) => a.id), isNot(contains('open')));
  });

  test('登录方式由源自己决定:B 站扫码,脚本源账密', () {
    final accounts = {for (final a in sourceAccounts()) a.id: a};

    expect(accounts[kBiliSourceId]!.kind, SourceLoginKind.qr);
    expect(accounts['picacg']!.kind, SourceLoginKind.password);
    expect(accounts['xiaojie_github']!.kind, SourceLoginKind.password);
  });

  test('按源反查凭据,拿到的是整组', () {
    final account = sourceAccountFor(_xiaojieNovel);

    expect(account.id, 'xiaojie_github');
    expect(account.sources, hasLength(2));
  });

  // B 站的登录态在 BiliAuth 里,不在 AuthStore 里。这里塞一份 AuthStore 侧的
  // bilibili token,登录态**仍应为假** —— 问错存放处正是行内按钮以前永远显示
  // 「未登录」的原因,反过来也会假装登录成功。
  test('扫码源的登录态不从账密存储里读', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthStore(
      preferences: prefs,
      secrets: _MemorySecretStore({'source.auth.$kBiliSourceId': 'token'}),
    );
    await auth.load();

    expect(auth.isLoggedIn(kBiliSourceId), isTrue, reason: '前提:账密存储里有值');

    final accounts = {for (final a in sourceAccounts()) a.id: a};
    expect(isSourceAccountLoggedIn(accounts[kBiliSourceId]!, auth), isFalse);
    expect(sourceAccountUser(accounts[kBiliSourceId]!, auth), isNull);
  });

  test('账密源的登录态与用户名从 AuthStore 读', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth.xiaojie_github.username': 'reader',
      'auth.xiaojie_github.nickname': '读者',
    });
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthStore(
      preferences: prefs,
      secrets: _MemorySecretStore({'source.auth.xiaojie_github': 'token'}),
    );
    await auth.load();

    final account = sourceAccountFor(_xiaojieManga);
    expect(isSourceAccountLoggedIn(account, auth), isTrue);
    expect(sourceAccountUser(account, auth), '读者');
  });
}
