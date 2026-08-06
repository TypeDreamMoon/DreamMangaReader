import 'dart:async';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/features/anime/anime_player_page.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_session_controller.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_state.dart';
import 'package:dream_manga_reader/features/anime/playback/player_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

class _PageFakeAdapter implements PlayerAdapter {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);
  final opened = <VideoTrack>[];

  @override
  Stream<bool> get playing => playingController.stream;
  @override
  Stream<bool> get buffering => bufferingController.stream;
  @override
  Stream<Duration> get position => positionController.stream;
  @override
  Stream<bool> get completed => completedController.stream;
  @override
  Stream<Object> get errors => errorController.stream;
  @override
  Future<void> open(VideoTrack track) async => opened.add(track);
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> dispose() async {
    await playingController.close();
    await bufferingController.close();
    await positionController.close();
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
