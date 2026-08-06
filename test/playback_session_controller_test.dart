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
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);

  final List<VideoTrack> opened = [];
  final List<Duration> seeks = [];
  final List<Completer<void>> pauseGates = [];
  bool failOpen = false;
  int playCalls = 0;
  int pauseCalls = 0;

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
  Future<void> open(VideoTrack track) async {
    opened.add(track);
    if (failOpen) throw StateError('fixture open failure');
  }

  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async {
    pauseCalls++;
    if (pauseGates.isNotEmpty) await pauseGates.removeAt(0).future;
  }

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
  test('PlaybackState copyWith can explicitly clear a pending seek', () {
    final state = const PlaybackState(
      phase: PlaybackPhase.playing,
      pendingSeekTarget: Duration(minutes: 4),
      seeking: true,
    ).copyWith(
      clearPendingSeekTarget: true,
      seeking: false,
    );

    expect(state.pendingSeekTarget, isNull);
    expect(state.seeking, isFalse);
  });

  test('pending seek ignores zero and recovery uses the pending target',
      () async {
    final adapter = _FakePlayerAdapter();
    final progress = <Duration>[];
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
      onProgress: (position, _) => progress.add(position),
    );
    await controller.start(const [_track480], _track480);
    adapter.playingController.add(true);
    adapter.positionController.add(const Duration(seconds: 40));

    await controller.seekTo(
      const Duration(minutes: 8),
      resumeAfterSeek: true,
    );
    adapter.positionController.add(Duration.zero);
    adapter.positionController.add(const Duration(seconds: 41));
    adapter.errorController.add(StateError('decoder boundary'));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.pendingSeekTarget, const Duration(minutes: 8));
    expect(controller.state.position, const Duration(minutes: 8));
    expect(progress, [const Duration(seconds: 40)]);
    expect(adapter.seeks.last, const Duration(minutes: 8));
    await controller.dispose();
  });

  test('pending seek near the beginning does not accept transient zero',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
    );
    await controller.start(const [_track480], _track480);

    await controller.seekTo(
      const Duration(seconds: 2),
      resumeAfterSeek: true,
    );
    adapter.positionController.add(Duration.zero);

    expect(controller.state.pendingSeekTarget, const Duration(seconds: 2));
    expect(controller.state.seeking, isTrue);
    expect(adapter.playCalls, 0);
    await controller.dispose();
  });

  test('pending seek accepts a coarse backend jump up to ten seconds ahead',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
    );
    await controller.start(const [_track480], _track480);

    await controller.seekTo(
      const Duration(minutes: 5),
      resumeAfterSeek: false,
    );
    adapter.positionController.add(const Duration(minutes: 5, seconds: 8));

    expect(controller.state.pendingSeekTarget, isNull);
    expect(controller.state.position, const Duration(minutes: 5, seconds: 8));
    expect(controller.state.seeking, isFalse);
    await controller.dispose();
  });

  test('a stalled near-end session seek recovers at the explicit target', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final controller = PlaybackSessionController(
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) async {},
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.durationController.add(const Duration(seconds: 100));

      controller.seekTo(
        const Duration(seconds: 95),
        resumeAfterSeek: true,
      );
      async.flushMicrotasks();
      adapter.bufferingController.add(true);
      expect(controller.state.position, const Duration(seconds: 95));
      async.elapse(const Duration(seconds: 8));
      async.flushMicrotasks();

      expect(adapter.opened, hasLength(2));
      expect(adapter.seeks.last, const Duration(seconds: 95));
      expect(controller.state.position, const Duration(seconds: 95));
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('a newer seek supersedes delayed work from an older seek', () async {
    final adapter = _FakePlayerAdapter();
    final firstPause = Completer<void>();
    adapter.pauseGates.add(firstPause);
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);

    final first = controller.seekTo(
      const Duration(minutes: 3),
      resumeAfterSeek: true,
    );
    final second = controller.seekTo(
      const Duration(minutes: 7),
      resumeAfterSeek: false,
    );
    await second;
    firstPause.complete();
    await first;

    expect(adapter.seeks, [const Duration(minutes: 7)]);
    expect(controller.state.pendingSeekTarget, const Duration(minutes: 7));
    expect(controller.state.position, const Duration(minutes: 7));
    await controller.dispose();
  });

  test('a backend position near the target confirms the pending seek',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);

    await controller.seekTo(
      const Duration(minutes: 8),
      resumeAfterSeek: false,
    );
    adapter.positionController.add(
      const Duration(minutes: 8, seconds: 2),
    );

    expect(controller.state.pendingSeekTarget, isNull);
    expect(controller.state.seeking, isFalse);
    expect(
      controller.state.position,
      const Duration(minutes: 8, seconds: 2),
    );
    await controller.dispose();
  });

  test('a confirmed seek does not resume when resumeAfterSeek is false',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);

    await controller.seekTo(
      const Duration(minutes: 5),
      resumeAfterSeek: false,
    );
    adapter.positionController.add(const Duration(minutes: 5));
    await Future<void>.delayed(Duration.zero);

    expect(adapter.playCalls, 0);
    await controller.dispose();
  });

  test('a confirmed seek resumes when resumeAfterSeek is true', () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);

    await controller.seekTo(
      const Duration(minutes: 5),
      resumeAfterSeek: true,
    );
    expect(adapter.playCalls, 0);

    adapter.positionController.add(const Duration(minutes: 5));
    await Future<void>.delayed(Duration.zero);

    expect(adapter.playCalls, 1);
    await controller.dispose();
  });

  test('initial playback seeks only after opening the track', () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );

    await controller.start(
      const [_track480],
      _track480,
      initialPosition: const Duration(seconds: 83),
    );

    expect(adapter.opened, [_track480]);
    expect(adapter.seeks, [const Duration(seconds: 83)]);
    await controller.dispose();
  });

  test('progress callback emits once per changed integer second', () async {
    final adapter = _FakePlayerAdapter();
    final progress = <(Duration, Duration)>[];
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
      onProgress: (position, duration) => progress.add((position, duration)),
    );
    await controller.start(const [_track480], _track480);

    adapter.durationController.add(const Duration(minutes: 24));
    adapter.positionController.add(const Duration(milliseconds: 12100));
    adapter.positionController.add(const Duration(milliseconds: 12900));
    adapter.positionController.add(const Duration(milliseconds: 13000));

    expect(progress, [
      (const Duration(seconds: 12), const Duration(minutes: 24)),
      (const Duration(seconds: 13), const Duration(minutes: 24)),
    ]);
    await controller.dispose();
  });

  test('pausing playback invokes the persistence callback', () async {
    final adapter = _FakePlayerAdapter();
    var pauses = 0;
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
      onPaused: () => pauses++,
    );
    await controller.start(const [_track480], _track480);

    adapter.playingController.add(true);
    adapter.playingController.add(false);

    expect(pauses, 1);
    await controller.dispose();
  });

  test('near-end resume restarts from zero', () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    adapter.durationController.add(const Duration(seconds: 100));

    await controller.start(
      const [_track480],
      _track480,
      initialPosition: const Duration(seconds: 95),
    );

    expect(adapter.seeks, isEmpty);
    expect(controller.state.position, Duration.zero);
    await controller.dispose();
  });

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
