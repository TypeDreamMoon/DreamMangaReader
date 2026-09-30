import 'dart:async';
import 'dart:io';

import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/local_media_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:dream_manga_reader/core/platform/local_media_bridge.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/player_adapter.dart';
import 'package:dream_manga_reader/features/anime/playback/subtitle_option.dart';
import 'package:dream_manga_reader/features/local/local_player_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('opens the first episode and resumes from history',
      (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 2);
    addTearDown(() {
      unawaited(fixture.adapter.dispose());
      fixture.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      fixture.anime.saveProgress(
        sourceId: LocalSource.id,
        animeId: fixture.libraryId,
        title: '测试剧集',
        episodeId: 'item-1',
        episodeName: 'E01',
        episodeIndex: 0,
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 20),
      );
      await fixture.anime.flushPending();
    });

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    expect(fixture.adapter.openStarts, isNotEmpty);
    expect(fixture.adapter.openStarts.first, const Duration(minutes: 5));
    expect(fixture.adapter.opened.first.url, fixture.videoUri(0));
    expect(fixture.adapter.opened.first.hls, isFalse);
    expect(find.text('E01'), findsOneWidget);
  });

  testWidgets('completion advances to the next episode', (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 2);
    addTearDown(() {
      unawaited(fixture.adapter.dispose());
      fixture.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();
    expect(fixture.adapter.opened.length, 1);

    fixture.adapter.completedController.add(true);
    // 换集要经过 flushPending + markPlayed(真落盘),假异步区里必须喂真 I/O。
    await _settleIo(tester);

    expect(fixture.adapter.opened.length, 2);
    expect(fixture.adapter.opened.last.url, fixture.videoUri(1));
  });

  testWidgets('content uri goes through the bridge and releases the fd',
      (tester) async {
    final calls = <String>[];
    const channel = MethodChannel(LocalMediaBridge.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'openFd') {
        return <String, Object?>{'fd': 42, 'path': '/proc/self/fd/42'};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final fixture = await _Fixture.create(tester, itemCount: 1);
    addTearDown(() {
      unawaited(fixture.adapter.dispose());
      fixture.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host(
      bridge: LocalMediaBridge(channel: channel, isAndroid: true),
      location: 'content://com.android.providers.media.documents/tree/x/E01.mkv',
    ));
    // 桥走 MethodChannel,响应要真事件循环才回得来,所以不能用 pumpAndSettle。
    await _settleIo(tester);

    expect(calls, contains('openFd'));
    expect(fixture.adapter.opened.first.url, contains('proc/self/fd/42'));

    // 退出播放页 → 释放 fd。
    await tester.pumpWidget(const SizedBox.shrink());
    await _settleIo(tester);
    expect(calls, contains('releaseFd'));
  });

  testWidgets('reports progress back to the anime library store',
      (tester) async {
    final fixture = await _Fixture.create(tester, itemCount: 1);
    addTearDown(() {
      unawaited(fixture.adapter.dispose());
      fixture.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    fixture.adapter.durationController.add(const Duration(minutes: 10));
    fixture.adapter.playingController.add(true);
    await tester.pump();
    fixture.adapter.positionController.add(const Duration(seconds: 45));
    await tester.pump();

    final entry = fixture.anime.historyFor(LocalSource.id, fixture.libraryId);
    expect(entry, isNotNull);
    expect(entry!.episodeId, 'item-1');
    expect(entry.positionSeconds, 45);
    expect(entry.durationSeconds, 600);
  });
}

/// 交替 pump/runAsync:让假异步区里「真 I/O + await 链」能一步步走完。
///
/// 落盘(写索引/SharedPreferences)与 MethodChannel 响应都要真事件循环才回得来,
/// 假异步区里只 pump 不动它们;轮数不够时 await 链会停在中间(实测 8 轮不够、24 轮够)。
Future<void> _settleIo(WidgetTester tester, {int rounds = 24}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump();
  }
}

class _Fixture {
  _Fixture({
    required this.root,
    required this.store,
    required this.anime,
    required this.adapter,
    required this.library,
    required this.items,
    required this.videos,
  });

  final Directory root;
  final LocalMediaStore store;
  final AnimeLibraryStore anime;
  final _PageFakeAdapter adapter;
  final LocalLibrary library;
  final List<LocalMediaItem> items;
  final List<String> videos;
  String libraryId = '';

  static Future<_Fixture> create(WidgetTester tester,
      {int itemCount = 2}) async {
    SharedPreferences.setMockInitialValues(const {
      'anime.player.autoPlay': true,
      'anime.player.loopMode': 'none',
    });
    // 必须用 sync 版:假异步区里 `await createTemp()` 这种真 I/O 永远不完成。
    final root = Directory.systemTemp.createTempSync('local_player_page');
    final store = LocalMediaStore(rootProvider: () async => root.path);
    final anime = AnimeLibraryStore(persistDelay: Duration.zero);
    final adapter = _PageFakeAdapter();
    final videos = <String>[
      for (var i = 1; i <= itemCount; i++)
        '${root.path}${Platform.pathSeparator}Show.E'
            '${i.toString().padLeft(2, '0')}.mkv',
    ];
    for (final video in videos) {
      File(video).writeAsBytesSync(List<int>.filled(4096, 5));
    }
    _Fixture? built;
    final result = await tester.runAsync(() async {
      await anime.load();
      await store.load();
      final library = await store.addLibrary(
        name: '测试剧集',
        kind: LocalLibraryKind.folder,
        path: root.path,
        items: [
          for (var i = 1; i <= itemCount; i++)
            LocalMediaItem(
              id: 'item-$i',
              libraryId: '',
              title: 'E${i.toString().padLeft(2, '0')}',
              location: videos[i - 1],
              sizeBytes: 4096,
              addedAt: 1,
            ),
        ],
      );
      built = _Fixture(
        root: root,
        store: store,
        anime: anime,
        adapter: adapter,
        library: library,
        items: store.items(library.id),
        videos: videos,
      );
      built!.libraryId = library.id;
      return built!;
    });
    return result ?? built!;
  }

  String videoUri(int index) =>
      Uri.file(videos[index], windows: Platform.isWindows).toString();

  Widget host({LocalMediaBridge? bridge, String? location}) => LocalMediaScope(
        store: store,
        child: AnimeLibraryScope(
          store: anime,
          child: MaterialApp(
            theme: buildTheme(AppThemeVariant.light),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: LocalPlayerPage(
              library: library,
              items: location == null
                  ? items
                  : [
                      for (final item in items)
                        item.copyWith(location: location),
                    ],
              dependencies: LocalPlayerDependencies(
                player: adapter,
                videoBuilder: (_) => const ColoredBox(color: Colors.black),
              ),
              bridge: bridge,
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
