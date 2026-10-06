import 'package:dream_manga_reader/core/storage/secret_store.dart';
import 'package:dream_manga_reader/core/sync/sync_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `load()` 里的 IamAuth 也读安全存储,而它不走注入的 [SecretStore]。
/// flutter_secure_storage 没有官方测试替身,把它的 MethodChannel 换成内存表。
void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final store = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'write':
        if (key != null) store[key] = args['value'] as String? ?? '';
        return null;
      case 'read':
        return key == null ? null : store[key];
      case 'delete':
        store.remove(key);
        return null;
      case 'readAll':
        return Map<String, String>.from(store);
      case 'deleteAll':
        store.clear();
        return null;
      case 'containsKey':
        return store.containsKey(key);
      default:
        return null;
    }
  });
}

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
    if (failWrites) throw StateError('secure write failed');
    values[key] = value;
  }
}

const _legacyPassKey = 'sync.webdav.pass';
const _securePassKey = 'sync.webdav.password';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sync = SyncController.instance;
  late _MemorySecretStore secrets;

  setUp(() {
    _mockSecureStorage();
    secrets = _MemorySecretStore();
  });

  /// 装一份 prefs 初值,并让单例用上它 + 内存安全存储。返回同一个 prefs 实例
  /// (setMockInitialValues 每次会换新实例,不共享就断言的是另一份数据)。
  Future<SharedPreferences> boot(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    sync.debugConfigure(secrets: secrets, preferences: prefs);
    return prefs;
  }

  // WebDAV 密码曾经明文躺在 SharedPreferences 里——Windows 上那就是个谁都能打开
  // 的 JSON 文件。现在只走安全存储,旧键只当迁移来源。
  group('webdav password', () {
    test('保存时进安全存储,不落明文键', () async {
      final prefs = await boot(const <String, Object>{});
      await sync.saveConfig(
        url: 'https://dav.example.com/',
        username: 'alice',
        password: 's3cret',
        auto: false,
      );

      expect(secrets.values[_securePassKey], 's3cret');
      expect(prefs.getString(_legacyPassKey), isNull);
      expect(prefs.getString('sync.webdav.user'), 'alice');
    });

    test('旧的明文密码在启动时被搬走并删掉', () async {
      final prefs = await boot(const <String, Object>{
        'sync.webdav.url': 'https://dav.example.com/',
        'sync.webdav.user': 'alice',
        _legacyPassKey: 'legacy-pass',
      });

      await sync.load();

      expect(sync.password, 'legacy-pass');
      expect(secrets.values[_securePassKey], 'legacy-pass');
      expect(prefs.getString(_legacyPassKey), isNull);
    });

    test('清空密码时安全存储里的那份也删掉', () async {
      final prefs = await boot(const <String, Object>{});
      secrets.values[_securePassKey] = 'old';

      await sync.saveConfig(
        url: 'https://dav.example.com/',
        username: 'alice',
        password: '',
        auto: false,
      );

      expect(secrets.values.containsKey(_securePassKey), isFalse);
      expect(prefs.getString(_legacyPassKey), isNull);
    });

    test('安全存储写不进去时退回旧键,而不是把配置弄丢', () async {
      final prefs = await boot(const <String, Object>{});
      secrets.failWrites = true;

      await sync.saveConfig(
        url: 'https://dav.example.com/',
        username: 'alice',
        password: 's3cret',
        auto: false,
      );

      expect(prefs.getString(_legacyPassKey), 's3cret');
      expect(secrets.values.containsKey(_securePassKey), isFalse);

      // 安全存储恢复后,下一次 load 自动完成迁移。
      secrets.failWrites = false;
      await sync.load();
      expect(secrets.values[_securePassKey], 's3cret');
      expect(prefs.getString(_legacyPassKey), isNull);
    });
  });
}
