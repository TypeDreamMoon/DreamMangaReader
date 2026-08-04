import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final originalSources = List<SourceMeta>.of(registeredSources);

  tearDown(() {
    registeredSources = List<SourceMeta>.of(originalSources);
  });

  test('source metadata recognizes all supported kinds', () {
    const manga = SourceMeta(id: 'm', name: 'M', script: '');
    const anime = SourceMeta(id: 'a', name: 'A', script: '', kind: 'anime');
    const novel = SourceMeta(id: 'n', name: 'N', script: '', kind: 'novel');

    expect(manga.isManga, true);
    expect(anime.isAnime, true);
    expect(novel.isNovel, true);
  });

  test('source controller keeps manga and novel selections apart', () async {
    SharedPreferences.setMockInitialValues({
      'source.current.manga': 'm',
      'source.current.novel': 'n',
    });
    registeredSources = const [
      SourceMeta(id: 'm', name: 'M', script: ''),
      SourceMeta(id: 'n', name: 'N', script: '', kind: 'novel'),
    ];

    final controller = SourceController();
    await controller.load();

    expect(controller.currentFor('manga')?.id, 'm');
    expect(controller.currentFor('novel')?.id, 'n');
  });

  test('legacy current source migrates only to manga selection', () async {
    SharedPreferences.setMockInitialValues({'source.current': 'm2'});
    registeredSources = const [
      SourceMeta(id: 'm1', name: 'M1', script: ''),
      SourceMeta(id: 'm2', name: 'M2', script: ''),
      SourceMeta(id: 'n', name: 'N', script: '', kind: 'novel'),
    ];

    final controller = SourceController();
    await controller.load();

    expect(controller.current?.id, 'm2');
    expect(controller.currentFor('novel')?.id, 'n');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('source.current.manga'), 'm2');
  });

  test('same-id source refresh replaces the selected script instance', () {
    const oldSource = SourceMeta(
      id: 'misskon',
      name: 'MissKon',
      script: 'old script',
    );
    const refreshedSource = SourceMeta(
      id: 'misskon',
      name: 'MissKon',
      script: 'refreshed script',
      useWebView: true,
    );
    registeredSources = const [oldSource];
    final controller = SourceController(oldSource);
    var notifications = 0;
    controller.addListener(() => notifications++);

    registeredSources = const [refreshedSource];
    final current = controller.currentFor('manga');
    controller.selectFor('manga', current!);

    expect(current, same(refreshedSource));
    expect(controller.currentFor('manga'), same(refreshedSource));
    expect(notifications, 1);
  });
}
