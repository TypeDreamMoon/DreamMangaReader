import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to Gitee and persists GitHub preference', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    addTearDown(store.dispose);

    await store.load();
    expect(store.updateSource, UpdateSource.gitee);

    store.updateSource = UpdateSource.github;
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lib.updateSource'), 'github');
  });

  test('unknown source migrates to Gitee', () async {
    SharedPreferences.setMockInitialValues({'lib.updateSource': 'retired'});
    final store = LibraryStore();
    addTearDown(store.dispose);

    await store.load();

    expect(store.updateSource, UpdateSource.gitee);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lib.updateSource'), 'gitee');
  });

  test('exports and imports the preferred update source', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LibraryStore();
    addTearDown(store.dispose);
    await store.load();
    store.updateSource = UpdateSource.github;

    expect(store.exportData()['updateSource'], 'github');

    await store.importData({
      'updateSource': 'gitee',
    }, replaceFavorites: false, replaceHistory: false);
    expect(store.updateSource, UpdateSource.gitee);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lib.updateSource'), 'gitee');
  });
}
