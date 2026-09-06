import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecretStore implements SecretStore {
  _MemorySecretStore([Map<String, String>? values])
      : values = Map<String, String>.of(values ?? const {});

  final Map<String, String> values;
  bool failWrites = false;

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('no keystore');
    values[key] = value;
  }
}

const _legacyKey = 'lib.translateLlmKey';
const _secretKey = 'translate.llm.apiKey';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('迁移旧的明文密钥:搬进 SecretStore 并删掉 prefs 里的明文', () async {
    SharedPreferences.setMockInitialValues({
      _legacyKey: 'sk-plaintext',
      'lib.translateLlmBase': 'https://api.example.com/v1',
    });
    final secrets = _MemorySecretStore();
    final store = LibraryStore(secrets: secrets);
    await store.load();

    expect(store.translateLlmKey, 'sk-plaintext');
    expect(secrets.values[_secretKey], 'sk-plaintext');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_legacyKey), isNull);
    // 非敏感项照旧走 prefs。
    expect(store.translateLlmBase, 'https://api.example.com/v1');
  });

  test('已在 SecretStore 里的密钥优先,明文残留被清掉', () async {
    SharedPreferences.setMockInitialValues({_legacyKey: 'sk-stale'});
    final secrets = _MemorySecretStore({_secretKey: 'sk-secure'});
    final store = LibraryStore(secrets: secrets);
    await store.load();

    expect(store.translateLlmKey, 'sk-secure');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_legacyKey), isNull);
  });

  test('新写入的密钥只进 SecretStore,不写 SharedPreferences', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final secrets = _MemorySecretStore();
    final store = LibraryStore(secrets: secrets);
    await store.load();

    await store.setTranslateLlmKey('sk-new');
    expect(store.translateLlmKey, 'sk-new');
    expect(secrets.values[_secretKey], 'sk-new');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_legacyKey), isNull);
    expect(
      prefs.getKeys().where((k) => prefs.get(k) == 'sk-new'),
      isEmpty,
      reason: '密钥不该出现在任何 prefs 键上',
    );
  });

  test('清空密钥会把 SecretStore 里的条目删掉', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final secrets = _MemorySecretStore({_secretKey: 'sk-old'});
    final store = LibraryStore(secrets: secrets);
    await store.load();

    await store.setTranslateLlmKey('');
    expect(store.translateLlmKey, '');
    expect(secrets.values.containsKey(_secretKey), isFalse);
  });

  test('安全存储不可用时不回退明文:内存里可用,prefs 里没有', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final secrets = _MemorySecretStore()..failWrites = true;
    final store = LibraryStore(secrets: secrets);
    await store.load();

    await store.setTranslateLlmKey('sk-nokeystore');
    expect(store.translateLlmKey, 'sk-nokeystore');
    expect(secrets.values, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_legacyKey), isNull);
  });

  test('密钥不进导出/同步载荷', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final secrets = _MemorySecretStore();
    final store = LibraryStore(secrets: secrets);
    await store.load();
    await store.setTranslateLlmKey('sk-secret');

    expect(store.exportData().toString(), isNot(contains('sk-secret')));
  });
}
