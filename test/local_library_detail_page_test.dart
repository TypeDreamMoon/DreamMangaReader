import 'dart:async';
import 'dart:io';

import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/local_media_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/player_adapter.dart';
import 'package:dream_manga_reader/features/anime/playback/subtitle_option.dart';
import 'package:dream_manga_reader/features/local/local_library_detail_page.dart';
import 'package:dream_manga_reader/features/local/local_player_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('lists episodes with watched and missing badges', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 3);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 第三条的源文件已经不在磁盘上了 → 「文件不存在」徽章。
    fixture.videos[2].deleteSync();
    await tester.runAsync(() => fixture.store.markPlayed(
          'item-2',
          position: const Duration(minutes: 1),
          duration: const Duration(minutes: 10),
        ));

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    expect(find.text('剧集'), findsOneWidget);
    expect(find.text('3 个条目'), findsOneWidget);
    expect(find.text('E01'), findsOneWidget);
    expect(find.text('E02'), findsOneWidget);
    expect(find.text('E03'), findsOneWidget);
    expect(find.text('已看'), findsOneWidget);
    expect(find.text('文件不存在'), findsOneWidget);
  });

  testWidgets('resume card restarts the episode from history', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 2);
    addTearDown(fixture.dispose);
    addTearDown(fixture.adapter.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      fixture.anime.saveProgress(
        sourceId: LocalSource.id,
        animeId: fixture.libraryId,
        title: '测试剧集',
        episodeId: 'item-2',
        episodeName: 'E02',
        episodeIndex: 1,
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 10),
      );
      await fixture.anime.flushPending();
    });

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    expect(find.text('继续观看'), findsOneWidget);
    await tester.tap(find.text('02:00'));
    // 落地的是番剧播放页(chrome 一直在动,pumpAndSettle 等不到静止)。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();

    expect(find.byType(LocalPlayerPage), findsOneWidget);
    expect(fixture.adapter.openStarts, isNotEmpty);
    expect(fixture.adapter.openStarts.first, const Duration(minutes: 2));
    expect(
      fixture.adapter.opened.first.url,
      Uri.file(fixture.videos[1].path, windows: true).toString(),
    );
  });

  testWidgets('tapping an episode row resumes from that episode history',
      (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 2);
    addTearDown(fixture.dispose);
    addTearDown(fixture.adapter.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      fixture.anime.saveProgress(
        sourceId: LocalSource.id,
        animeId: fixture.libraryId,
        title: '测试剧集',
        episodeId: 'item-2',
        episodeName: 'E02',
        episodeIndex: 1,
        position: const Duration(minutes: 7),
        duration: const Duration(minutes: 20),
      );
      await fixture.anime.flushPending();
    });

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    // 「继续观看」卡片也写着 E02,`.last` 才是列表里那一行。
    await tester.tap(find.text('E02').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();

    // 断点由列表页算好交给播放页(番剧播放页只在开播那一集收 initialPosition)。
    expect(find.byType(LocalPlayerPage), findsOneWidget);
    expect(fixture.adapter.openStarts, isNotEmpty);
    expect(fixture.adapter.openStarts.first, const Duration(minutes: 7));
    expect(
      fixture.adapter.opened.first.url,
      Uri.file(fixture.videos[1].path, windows: true).toString(),
    );
  });

  testWidgets('renaming an item changes the row title but keeps the parsed name',
      (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('local-rename-field')), '第一集·序幕');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final renamed = fixture.store.item('item-1')!;
    expect(renamed.customTitle, '第一集·序幕');
    expect(renamed.displayTitle, '第一集·序幕');
    // 解析出来的原名留着,重扫刷新 title 时不会把用户的名字冲掉。
    expect(renamed.title, 'E01');
    expect(find.text('第一集·序幕'), findsOneWidget);
    expect(find.text('E01'), findsNothing);
  });

  testWidgets('removing an item only drops the index entry', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 2);
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除条目'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(fixture.store.items(fixture.libraryId).length, 1);
    expect(fixture.videos.first.existsSync(), isTrue);
  });
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.store,
    required this.anime,
    required this.videos,
    required this.adapter,
  });

  final Directory root;
  final LocalMediaStore store;
  final AnimeLibraryStore anime;
  final List<File> videos;
  final _PageFakeAdapter adapter;
  String libraryId = '';

  static Future<_Fixture> create(WidgetTester tester, {int itemCount = 2}) async {
    SharedPreferences.setMockInitialValues(const {});
    final root = Directory.systemTemp.createTempSync('local_detail_page');
    final store = LocalMediaStore(rootProvider: () async => root.path);
    final anime = AnimeLibraryStore(persistDelay: Duration.zero);
    final adapter = _PageFakeAdapter();
    final folder = Directory('${root.path}${Platform.pathSeparator}Show')
      ..createSync(recursive: true);
    final videos = <File>[];
    for (var i = 1; i <= itemCount; i++) {
      videos.add(File('${folder.path}${Platform.pathSeparator}'
          'Show.E${i.toString().padLeft(2, '0')}.mkv')
        ..writeAsBytesSync(List<int>.filled(2048 * i, 7)));
    }
    final fixture = _Fixture(
      root: root,
      store: store,
      anime: anime,
      videos: videos,
      adapter: adapter,
    );
    final built = await tester.runAsync(() async {
      await anime.load();
      await store.load();
      final library = await store.addLibrary(
        name: '测试剧集',
        kind: LocalLibraryKind.folder,
        path: folder.path,
        items: [
          for (var i = 1; i <= itemCount; i++)
            LocalMediaItem(
              id: 'item-$i',
              libraryId: '',
              title: 'E${i.toString().padLeft(2, '0')}',
              location: videos[i - 1].path,
              sizeBytes: 2048 * i,
              addedAt: 1,
            ),
        ],
      );
      fixture.libraryId = library.id;
      return fixture;
    });
    return built!;
  }

  Widget host() => LocalMediaScope(
        store: store,
        child: AnimeLibraryScope(
          store: anime,
          child: MaterialApp(
            theme: buildTheme(AppThemeVariant.light),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: LocalLibraryDetailPage(
              libraryId: libraryId,
              playerDependencies: LocalPlayerDependencies(
                player: adapter,
                videoBuilder: (_) => const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      );

  void dispose() {
    store.dispose();
    anime.dispose();
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录清理失败不影响测试结论。
    }
  }
}

/// 播放器假实现,照抄 test/anime_player_page_test.dart 的 _PageFakeAdapter。
class _PageFakeAdapter implements PlayerAdapter {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);
  final subtitleController =
      StreamController<List<SubtitleOption>>.broadcast(sync: true);
  final opened = <VideoTrack>[];
  final openStarts = <Duration>[];
  final seeks = <Duration>[];
  final volumes = <double>[];
  final subtitlePicks = <SubtitleOption>[];
  int pauseCalls = 0;
  int playCalls = 0;

  @override
  Stream<bool> get playing => playingController.stream;
  @override
  Stream<bool> get buffering => bufferingController.stream;
  @override
  Stream<Duration> get position => positionController.stream;
  @override
  Stream<Duration> get duration => durationController.stream;
  @override
  Stream<Duration> get buffer => bufferController.stream;
  @override
  Stream<bool> get completed => completedController.stream;
  @override
  Stream<Object> get errors => errorController.stream;
  @override
  Stream<List<SubtitleOption>> get subtitles => subtitleController.stream;
  @override
  Future<void> open(VideoTrack track, {Duration startAt = Duration.zero}) async {
    opened.add(track);
    openStarts.add(startAt);
  }

  @override
  Future<void> rebuildDecoder(Duration resumePosition) async {}
  @override
  Future<void> pause() async => pauseCalls++;
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  final rates = <double>[];
  @override
  Future<void> setRate(double rate) async => rates.add(rate);
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setSubtitle(SubtitleOption option) async =>
      subtitlePicks.add(option);
  @override
  Future<void> dispose() async {
    await playingController.close();
    await bufferingController.close();
    await positionController.close();
    await durationController.close();
    await bufferController.close();
    await completedController.close();
    await errorController.close();
    await subtitleController.close();
  }
}
