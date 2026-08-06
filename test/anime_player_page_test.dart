import 'dart:async';
import 'dart:convert';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/features/anime/anime_player_page.dart';
import 'package:dream_manga_reader/features/anime/anime_player_controls.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_session_controller.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_state.dart';
import 'package:dream_manga_reader/features/anime/playback/player_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = VideoTrack(
  url: 'https://media.example.test/video.mp4',
  quality: '480p',
);
const _track360 = VideoTrack(
  url: 'https://media.example.test/video-360.mp4',
  quality: '360p',
);

Widget _host(PlaybackState state, {VoidCallback? onRetry}) => MaterialApp(
      home: Scaffold(
        body: AnimePlaybackSurface(
          state: state,
          video: const ColoredBox(
            key: ValueKey('video-surface'),
            color: Colors.black,
          ),
          onRetry: onRetry ?? () {},
        ),
      ),
    );

void main() {
  testWidgets('page resumes and stores current episode to the second',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final library = AnimeLibraryStore(persistDelay: Duration.zero);
    await library.load();
    addTearDown(library.dispose);
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimeLibraryScope(
        store: library,
        child: AnimePlayerPage(
          meta: const SourceMeta(
            id: 'test-anime',
            name: 'Test Anime',
            script: '',
            kind: 'anime',
          ),
          animeId: 'anime-1',
          animeTitle: '测试番剧',
          episodes: const [Chapter(id: 'ep-1', name: '第一集')],
          index: 0,
          initialPosition: const Duration(seconds: 83),
          dependencies: dependencies,
        ),
      ),
    ));
    await tester.pump();

    expect(adapter.seeks, [const Duration(seconds: 83)]);
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.positionController.add(const Duration(milliseconds: 84100));
    await tester.pump();
    expect(library.history.single.positionSeconds, 84);
    expect(library.history.single.episodeId, 'ep-1');
  });

  testWidgets('switching episode flushes the previous episode progress',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final library = AnimeLibraryStore(persistDelay: const Duration(hours: 1));
    await library.load();
    addTearDown(library.dispose);
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimeLibraryScope(
        store: library,
        child: AnimePlayerPage(
          meta: const SourceMeta(
            id: 'test-anime',
            name: 'Test Anime',
            script: '',
            kind: 'anime',
          ),
          animeId: 'anime-1',
          animeTitle: '测试番剧',
          episodes: const [
            Chapter(id: 'ep-1', name: '第一集'),
            Chapter(id: 'ep-2', name: '第二集'),
          ],
          index: 0,
          dependencies: dependencies,
        ),
      ),
    ));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.positionController.add(const Duration(seconds: 42));
    await tester.pump();

    await tester.tap(find.text('下一集'));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    final persisted = jsonDecode(prefs.getString('anime.history.v1')!) as List;
    expect(persisted.single['episodeId'], 'ep-1');
    expect(persisted.single['positionSeconds'], 42);
  });

  testWidgets('shows transient playback state without replacing the video',
      (tester) async {
    for (final entry in <(PlaybackState, String)>[
      (
        const PlaybackState(
          phase: PlaybackPhase.opening,
          selectedTrack: _track,
        ),
        '正在连接视频',
      ),
      (
        const PlaybackState(
          phase: PlaybackPhase.buffering,
          selectedTrack: _track,
        ),
        '正在缓冲',
      ),
      (
        const PlaybackState(
          phase: PlaybackPhase.recovering,
          selectedTrack: _track,
          message: '正在恢复播放（1/3）',
        ),
        '正在恢复播放（1/3）',
      ),
    ]) {
      await tester.pumpWidget(_host(entry.$1));
      expect(find.byKey(const ValueKey('video-surface')), findsOneWidget);
      expect(find.text(entry.$2), findsOneWidget);
    }
  });

  testWidgets('normal playing removes transient status', (tester) async {
    await tester.pumpWidget(_host(const PlaybackState(
      phase: PlaybackPhase.playing,
      selectedTrack: _track,
    )));

    expect(find.byKey(const ValueKey('video-surface')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('正在'), findsNothing);
  });

  testWidgets('terminal failure exposes a retry command', (tester) async {
    var retried = false;
    await tester.pumpWidget(_host(
      const PlaybackState(
        phase: PlaybackPhase.failed,
        selectedTrack: _track,
        message: '播放恢复失败：连接已断开',
      ),
      onRetry: () => retried = true,
    ));

    expect(find.text('播放失败'), findsOneWidget);
    expect(find.textContaining('连接已断开'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
  });

  testWidgets('page delegates opening and readiness to the session controller',
      (tester) async {
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(
        key: ValueKey('injected-video'),
        color: Colors.black,
      ),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();

    expect(adapter.opened, [_track]);
    expect(find.text('正在连接视频'), findsOneWidget);
    adapter.playingController.add(true);
    await tester.pump();

    expect(find.byKey(const ValueKey('injected-video')), findsOneWidget);
    expect(find.text('正在连接视频'), findsNothing);
  });

  testWidgets('manual quality switch reuses the loaded list', (tester) async {
    final adapter = _PageFakeAdapter();
    var loadCalls = 0;
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async {
        loadCalls++;
        return const [_track, _track360];
      },
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.byTooltip('选集 / 线路 / 设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('360p'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(adapter.opened.last, _track360);
    expect(loadCalls, 1);
  });

  testWidgets('complete offline episode bypasses online track resolution',
      (tester) async {
    final adapter = _PageFakeAdapter();
    var onlineLoads = 0;
    const offline = VideoTrack(
      url: 'file:///offline/index.m3u8',
      quality: '离线',
      hls: true,
    );
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async {
        onlineLoads++;
        return const [_track];
      },
      localTrackForEpisode: (_) => offline,
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();

    expect(adapter.opened, [offline]);
    expect(onlineLoads, 0);
  });

  testWidgets('page controls pause on drag and seek through the session',
      (tester) async {
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 10));
    adapter.positionController.add(const Duration(minutes: 2));
    adapter.playingController.add(true);
    await tester.pump();

    expect(find.byType(AnimePlayerControls), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(140, 0));
    await tester.pump();

    expect(adapter.pauseCalls, greaterThanOrEqualTo(1));
    expect(adapter.seeks.last, greaterThan(const Duration(minutes: 2)));
  });
}

class _PageFakeAdapter implements PlayerAdapter {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);
  final opened = <VideoTrack>[];
  final seeks = <Duration>[];
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
  Stream<bool> get completed => completedController.stream;
  @override
  Stream<Object> get errors => errorController.stream;
  @override
  Future<void> open(VideoTrack track) async => opened.add(track);
  @override
  Future<void> rebuildDecoder(Duration resumePosition) async {}
  @override
  Future<void> pause() async => pauseCalls++;
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> dispose() async {
    await playingController.close();
    await bufferingController.close();
    await positionController.close();
    await durationController.close();
    await completedController.close();
    await errorController.close();
  }
}

class _PageFakeTracks implements PlaybackTrackProvider {
  @override
  VideoTrack? alternateLine(VideoTrack current, List<VideoTrack> available) =>
      null;
  @override
  VideoTrack? lowerQuality(VideoTrack current, List<VideoTrack> available) =>
      null;
  @override
  VideoTrack? matchRefreshed(VideoTrack current, List<VideoTrack> refreshed) =>
      refreshed.firstOrNull;
  @override
  Future<List<VideoTrack>> refresh() async => const [_track];
}
