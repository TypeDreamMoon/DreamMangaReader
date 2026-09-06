import 'package:dream_manga_reader/app/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _day = Duration(hours: 24);

Future<LibraryStore> _store(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  final store = LibraryStore();
  await store.load();
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('从没弹过 → 该弹', () async {
    final store = await _store(const {});
    expect(store.updatePromptDue(), isTrue);
  });

  test('刚弹过 24h 内不再弹,满 24h 才放行', () async {
    final store = await _store(const {});
    final now = DateTime(2026, 9, 6).millisecondsSinceEpoch;
    store.markUpdatePrompted(now);

    expect(store.updatePromptDue(now), isFalse);
    expect(store.updatePromptDue(now + _day.inMilliseconds - 1), isFalse);
    expect(store.updatePromptDue(now + _day.inMilliseconds), isTrue);
  });

  test('闸门跨重启保留', () async {
    final store = await _store(const {});
    final now = DateTime(2026, 9, 6).millisecondsSinceEpoch;
    store.markUpdatePrompted(now);

    final restarted = LibraryStore();
    await restarted.load();
    expect(restarted.updatePromptDue(now), isFalse);
    expect(restarted.updatePromptDue(now + _day.inMilliseconds), isTrue);
  });

  test('跳过的版本不再弹,更高的版本照弹', () async {
    final store = await _store(const {});
    expect(store.isUpdateVersionSkipped('1.3.1'), isFalse);

    store.skipUpdateVersion('1.3.1');
    expect(store.isUpdateVersionSkipped('1.3.1'), isTrue);
    expect(store.isUpdateVersionSkipped('1.4.0'), isFalse);

    final restarted = LibraryStore();
    await restarted.load();
    expect(restarted.isUpdateVersionSkipped('1.3.1'), isTrue);
  });

  test('空版本号不算被跳过', () async {
    final store = await _store(const {});
    expect(store.isUpdateVersionSkipped(''), isFalse);
  });

  test('闸门状态是本机的,不进导出/同步载荷', () async {
    final store = await _store(const {});
    store
      ..markUpdatePrompted(DateTime(2026, 9, 6).millisecondsSinceEpoch)
      ..skipUpdateVersion('1.3.1');
    final exported = store.exportData();
    expect(exported.keys, isNot(contains('updatePromptAt')));
    expect(exported.keys, isNot(contains('updateSkipVersion')));
  });
}
