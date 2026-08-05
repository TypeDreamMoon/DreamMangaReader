import 'dart:async';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_session_controller.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_state.dart';
import 'package:dream_manga_reader/features/anime/playback/player_adapter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _track480 = VideoTrack(
  url: 'https://media.example.test/480p.m3u8',
  quality: '480p',
  hls: true,
);
const _track360 = VideoTrack(
  url: 'https://media.example.test/360p.m3u8',
  quality: '360p',
  hls: true,
);

class _FakePlayerAdapter implements PlayerAdapter {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);

  final List<VideoTrack> opened = [];
  final List<Duration> seeks = [];
  bool failOpen = false;

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
  Future<void> open(VideoTrack track) async {
    opened.add(track);
    if (failOpen) throw StateError('fixture open failure');
  }

  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
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

class _FakeTrackProvider implements PlaybackTrackProvider {
  List<VideoTrack> tracks = const [_track480, _track360];
  bool failRefresh = false;
  int refreshCalls = 0;

  @override
  Future<List<VideoTrack>> refresh() async {
    refreshCalls++;
    if (failRefresh) throw StateError('fixture refresh failure');
    return tracks;
  }

  @override
  VideoTrack? matchRefreshed(VideoTrack current, List<VideoTrack> refreshed) =>
      refreshed.where((track) => track.quality == current.quality).firstOrNull;

  @override
  VideoTrack? lowerQuality(VideoTrack current, List<VideoTrack> available) =>
      current.quality == '480p' ? _track360 : null;

  @override
  VideoTrack? alternateLine(VideoTrack current, List<VideoTrack> available) =>
      available.where((track) => track.url != current.url).firstOrNull;
}

void main() {
  test('opens the initial track and enters playing on readiness', () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );

    await controller.start(const [_track480, _track360], _track480);
    expect(controller.state.phase, PlaybackPhase.opening);
    adapter.playingController.add(true);
    expect(controller.state.phase, PlaybackPhase.playing);
    expect(adapter.opened, [_track480]);

    await controller.dispose();
  });

  test('an eight second stall reopens and resumes the saved position', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final delays = <Duration>[];
      final controller = PlaybackSessionController(
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (duration) async => delays.add(duration),
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.playingController.add(true);
      adapter.positionController.add(const Duration(seconds: 37));

      adapter.bufferingController.add(true);
      async.elapse(const Duration(seconds: 7));
      expect(adapter.opened, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(controller.state.phase, PlaybackPhase.opening);
      expect(adapter.opened, hasLength(2));
      expect(adapter.seeks.last, const Duration(seconds: 37));
      expect(delays, [const Duration(seconds: 1)]);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('a player error recovers immediately but user pause does not', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final controller = PlaybackSessionController(
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) async {},
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.errorController.add(StateError('connection reset'));
      async.flushMicrotasks();
      expect(adapter.opened, hasLength(2));

      controller.setUserPaused(true);
      adapter.bufferingController.add(true);
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(adapter.opened, hasLength(2));
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('leaving a transient buffer returns the visible state to playing',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);
    adapter.playingController.add(true);
    adapter.bufferingController.add(true);
    expect(controller.state.phase, PlaybackPhase.buffering);

    adapter.bufferingController.add(false);
    expect(controller.state.phase, PlaybackPhase.playing);

    await controller.dispose();
  });

  test('three failed rounds use one two four second backoff then fail', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final provider = _FakeTrackProvider();
      final delays = <Duration>[];
      final controller = PlaybackSessionController(
        player: adapter,
        tracks: provider,
        delay: (duration) async => delays.add(duration),
      );
      controller.start(const [_track480, _track360], _track480);
      async.flushMicrotasks();
      adapter.failOpen = true;
      provider.failRefresh = true;
      adapter.errorController.add(StateError('network down'));
      async.flushMicrotasks();

      expect(controller.state.phase, PlaybackPhase.failed);
      expect(delays, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(controller.state.position, Duration.zero);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('fifteen stable seconds reset the recovery round', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final delays = <Duration>[];
      final controller = PlaybackSessionController(
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (duration) async => delays.add(duration),
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.errorController.add(StateError('first'));
      async.flushMicrotasks();
      adapter.playingController.add(true);
      async.elapse(const Duration(seconds: 15));
      adapter.errorController.add(StateError('second'));
      async.flushMicrotasks();

      expect(delays, [const Duration(seconds: 1), const Duration(seconds: 1)]);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('consecutive failures advance from reopen to refresh to lower quality',
      () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final provider = _FakeTrackProvider();
      final controller = PlaybackSessionController(
        player: adapter,
        tracks: provider,
        delay: (_) async {},
      );
      controller.start(const [_track480, _track360], _track480);
      async.flushMicrotasks();

      adapter.errorController.add(StateError('first disconnect'));
      async.flushMicrotasks();
      adapter.errorController.add(StateError('expired URL'));
      async.flushMicrotasks();
      adapter.errorController.add(StateError('insufficient throughput'));
      async.flushMicrotasks();

      expect(provider.refreshCalls, 1);
      expect(adapter.opened, [_track480, _track480, _track480, _track360]);
      expect(controller.state.selectedTrack, _track360);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('a newer start invalidates recovery work from the previous episode', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final pendingDelays = <Completer<void>>[];
      final controller = PlaybackSessionController(
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) {
          final completer = Completer<void>();
          pendingDelays.add(completer);
          return completer.future;
        },
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.errorController.add(StateError('old episode error'));
      async.flushMicrotasks();
      expect(pendingDelays, hasLength(1));

      controller.start(const [_track360], _track360);
      async.flushMicrotasks();
      pendingDelays.single.complete();
      async.flushMicrotasks();

      expect(controller.state.selectedTrack, _track360);
      expect(adapter.opened.last, _track360);
      controller.dispose();
      async.flushMicrotasks();
    });
  });
}
