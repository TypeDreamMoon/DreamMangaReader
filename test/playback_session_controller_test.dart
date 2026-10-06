import 'dart:async';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_messages.dart';
import 'package:dream_manga_reader/features/anime/playback/subtitle_option.dart';
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
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);

  final List<VideoTrack> opened = [];
  final List<Duration> seeks = [];
  final List<Duration> openStarts = [];
  final List<Duration> decoderRebuilds = [];
  final List<Completer<void>> pauseGates = [];
  bool failOpen = false;

  /// true = 后端收下了 startAt 却没落上去(libmpv 在文件就绪前吞掉 seek 的现场)。
  bool dropStartAt = false;
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
  Stream<Duration> get buffer => bufferController.stream;
  @override
  Stream<bool> get completed => completedController.stream;
  @override
  Stream<Object> get errors => errorController.stream;
  @override
  Stream<List<SubtitleOption>> get subtitles => const Stream.empty();

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSubtitle(SubtitleOption option) async {}

  @override
  Future<void> open(VideoTrack track, {Duration startAt = Duration.zero}) async {
    opened.add(track);
    openStarts.add(startAt);
    if (failOpen) throw StateError('fixture open failure');
    if (dropStartAt) return;
    if (startAt > Duration.zero) positionController.add(startAt);
  }

  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> rebuildDecoder(Duration resumePosition) async => failOpen
      ? throw StateError('fixture rebuild failure')
      : decoderRebuilds.add(resumePosition);
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
    await bufferController.close();
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

/// 文案用可辨认的英文占位:这层只关心「有没有把文案透出去」,不关心具体译文。
const _messages = PlaybackMessages(
  noRoute: 'no route',
  bufferTimeout: 'buffer timeout',
  recovering: _recovering,
  recoverFailed: _recoverFailed,
  configureFailed: _configureFailed,
  gatewayFallbackFailed: _gatewayFallbackFailed,
);

String _recovering(int attempt, int total) => 'recovering $attempt/$total';

String _recoverFailed(String detail) => 'recover failed: $detail';

String _configureFailed(String key, String detail) =>
    'cannot configure $key: $detail';

String _gatewayFallbackFailed(String detail) => 'gateway fallback: $detail';

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
      messages: _messages,
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

  test('confirmed playback ignores transient zero before boundary recovery',
      () async {
    final adapter = _FakePlayerAdapter();
    final progress = <Duration>[];
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
      onProgress: (position, _) => progress.add(position),
    );
    await controller.start(const [_track480], _track480);
    adapter.playingController.add(true);
    adapter.positionController.add(const Duration(minutes: 7));

    adapter.positionController.add(Duration.zero);
    adapter.errorController.add(StateError('decoder boundary'));
    await Future<void>.delayed(Duration.zero);

    expect(progress, [const Duration(minutes: 7)]);
    expect(adapter.decoderRebuilds, [const Duration(minutes: 7)]);
    expect(controller.state.position, const Duration(minutes: 7));
    await controller.dispose();
  });

  test('pending seek near the beginning does not accept transient zero',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      messages: _messages,
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
      messages: _messages,
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
        messages: _messages,
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

      expect(adapter.opened, hasLength(1));
      expect(adapter.decoderRebuilds, [const Duration(seconds: 95)]);
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
      messages: _messages,
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
      messages: _messages,
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
      messages: _messages,
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
      messages: _messages,
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

  test('progress callback emits once per changed integer second', () async {
    final adapter = _FakePlayerAdapter();
    final progress = <(Duration, Duration)>[];
    final controller = PlaybackSessionController(
      messages: _messages,
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
      messages: _messages,
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
      messages: _messages,
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
      messages: _messages,
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

  // 后台里系统把解码停掉,缓冲当然不往前走 —— 那不是卡顿。原来切后台完全绕过
  // 会话层,武装着的定时器一到点就把一条好端端的会话拆了重建。
  test('a backgrounded session does not tear itself down while buffering', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final controller = PlaybackSessionController(
        messages: _messages,
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) async {},
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.playingController.add(true);
      adapter.positionController.add(const Duration(minutes: 3));

      adapter.bufferingController.add(true);
      controller.notifyBackgrounded(true);
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();

      expect(adapter.decoderRebuilds, isEmpty);
      expect(controller.state.phase, PlaybackPhase.buffering);

      // 回到前台闸重新上上:真死流照样救得回来。
      controller.notifyBackgrounded(false);
      async.elapse(const Duration(seconds: 8));
      async.flushMicrotasks();

      expect(adapter.decoderRebuilds, [const Duration(minutes: 3)]);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('an eight second stall reopens and resumes the saved position', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final delays = <Duration>[];
      final controller = PlaybackSessionController(
        messages: _messages,
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

      expect(controller.state.phase, PlaybackPhase.recovering);
      expect(adapter.opened, hasLength(1));
      expect(adapter.decoderRebuilds, [const Duration(seconds: 37)]);
      expect(delays, [const Duration(seconds: 1)]);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('a stall that rebuilds at zero does not send the viewer back to the start',
      () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final progress = <Duration>[];
      final controller = PlaybackSessionController(
        messages: _messages,
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) async {},
        onProgress: (position, _) => progress.add(position),
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.durationController.add(const Duration(minutes: 24));
      adapter.playingController.add(true);
      adapter.positionController.add(const Duration(minutes: 9));
      progress.clear();

      adapter.bufferingController.add(true);
      async.elapse(const Duration(seconds: 8));
      async.flushMicrotasks();
      expect(adapter.decoderRebuilds, [const Duration(minutes: 9)]);

      // 重建出来的解码器从头开始吐位置 —— 一帧都不能算数。
      adapter.durationController.add(Duration.zero);
      adapter.positionController.add(Duration.zero);
      adapter.positionController.add(const Duration(milliseconds: 96));
      expect(progress, isEmpty);
      expect(controller.state.position, const Duration(minutes: 9));

      // 时长回来了 = 文件重新打开了,这一刻补发的 seek 会被接受。
      adapter.durationController.add(const Duration(minutes: 24));
      async.flushMicrotasks();
      expect(adapter.seeks, [const Duration(minutes: 9)]);

      adapter.positionController.add(const Duration(minutes: 9, seconds: 1));
      expect(progress, [const Duration(minutes: 9, seconds: 1)]);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('a player error recovers immediately but user pause does not', () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final controller = PlaybackSessionController(
        messages: _messages,
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) async {},
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.errorController.add(StateError('connection reset'));
      async.flushMicrotasks();
      expect(adapter.opened, hasLength(1));
      expect(adapter.decoderRebuilds, [Duration.zero]);

      controller.setUserPaused(true);
      adapter.bufferingController.add(true);
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(adapter.opened, hasLength(1));
      expect(adapter.decoderRebuilds, [Duration.zero]);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('leaving a transient buffer returns the visible state to playing',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      messages: _messages,
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
        messages: _messages,
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
        messages: _messages,
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
        messages: _messages,
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
      expect(adapter.opened, [_track480, _track480, _track360]);
      expect(adapter.decoderRebuilds, [Duration.zero]);
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
        messages: _messages,
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

  test('the buffered head reaches the state, clamped and per whole second',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);
    adapter.durationController.add(const Duration(minutes: 24));

    adapter.bufferController.add(const Duration(seconds: 95));
    expect(controller.state.buffered, const Duration(seconds: 95));

    // 缓冲不可能超过片长 —— 越界会让进度条的白条画到轨道外面。
    adapter.bufferController.add(const Duration(minutes: 30));
    expect(controller.state.buffered, const Duration(minutes: 24));
    await controller.dispose();
  });

  test('reopening a stream drops the buffered head from the previous one',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.bufferController.add(const Duration(minutes: 3));

    await controller.start(const [_track360], _track360);

    expect(controller.state.buffered, Duration.zero);
    await controller.dispose();
  });

  test('a resume start hands the position to open, not to a post-open seek',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );

    await controller.start(
      const [_track480],
      _track480,
      initialPosition: const Duration(minutes: 12),
    );

    expect(adapter.openStarts, [const Duration(minutes: 12)]);
    expect(adapter.seeks, isEmpty);
    expect(controller.state.position, const Duration(minutes: 12));
    await controller.dispose();
  });

  test('a swallowed resume neither reports zero nor forgets the target',
      () async {
    final adapter = _FakePlayerAdapter()..dropStartAt = true;
    final progress = <Duration>[];
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
      onProgress: (position, _) => progress.add(position),
    );

    await controller.start(
      const [_track480],
      _track480,
      initialPosition: const Duration(minutes: 12),
    );
    // 播放器从头放起 —— 这些取样一个都不能算数,一算历史里的 12 分钟就没了。
    adapter.playingController.add(true);
    adapter.positionController.add(Duration.zero);
    adapter.positionController.add(const Duration(milliseconds: 104));
    adapter.positionController.add(const Duration(seconds: 1));

    expect(progress, isEmpty);
    expect(controller.state.position, const Duration(minutes: 12));

    // 时长到手 = 文件真的打开了,这一刻补发的 seek 一定会被接受。
    adapter.durationController.add(const Duration(minutes: 24));
    await Future<void>.delayed(Duration.zero);
    expect(adapter.seeks, [const Duration(minutes: 12)]);

    adapter.positionController.add(const Duration(minutes: 12));
    expect(progress, [const Duration(minutes: 12)]);
    await controller.dispose();
  });

  test('an unconfirmed resume gives up instead of freezing the progress bar',
      () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter()..dropStartAt = true;
      final controller = PlaybackSessionController(
        messages: _messages,
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) async {},
        resumeConfirmationTimeout: const Duration(seconds: 20),
      );
      controller.start(
        const [_track480],
        _track480,
        initialPosition: const Duration(minutes: 12),
      );
      async.flushMicrotasks();

      adapter.positionController.add(const Duration(seconds: 3));
      expect(controller.state.position, const Duration(minutes: 12));

      async.elapse(const Duration(seconds: 20));
      adapter.positionController.add(const Duration(seconds: 24));

      expect(controller.state.position, const Duration(seconds: 24));
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('an ad break resetting the timeline cannot reach the history', () async {
    final adapter = _FakePlayerAdapter();
    final progress = <Duration>[];
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
      onProgress: (position, _) => progress.add(position),
    );
    await controller.start(const [_track480], _track480);
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.playingController.add(true);
    adapter.positionController.add(const Duration(minutes: 12));
    progress.clear();

    // 拼进来的广告段带一个重置的 PTS,位置一下掉回片头。观众还在 12 分钟。
    adapter.positionController.add(Duration.zero);
    adapter.positionController.add(const Duration(milliseconds: 40));
    adapter.positionController.add(const Duration(seconds: 1));

    expect(progress, isEmpty);
    expect(controller.state.position, const Duration(minutes: 12));
    // 把观众拽回去,而不是让他从头看起。
    expect(adapter.seeks, [const Duration(minutes: 12)]);

    adapter.positionController.add(const Duration(minutes: 12, seconds: 1));
    expect(progress, [const Duration(minutes: 12, seconds: 1)]);
    await controller.dispose();
  });

  test('a reset that cannot be undone is accepted rather than fought forever',
      () {
    fakeAsync((async) {
      final adapter = _FakePlayerAdapter();
      final controller = PlaybackSessionController(
        messages: _messages,
        player: adapter,
        tracks: _FakeTrackProvider(),
        delay: (_) async {},
        resumeConfirmationTimeout: const Duration(seconds: 20),
        maxTimelineReanchors: 2,
      );
      controller.start(const [_track480], _track480);
      async.flushMicrotasks();
      adapter.durationController.add(const Duration(minutes: 24));
      adapter.positionController.add(const Duration(minutes: 12));

      // 每一轮:看回 12 分钟 → 又被重置 → 拽不回来,等确认窗口过了认命。
      for (var attempt = 0; attempt < 4; attempt++) {
        adapter.positionController.add(const Duration(minutes: 12));
        adapter.positionController.add(const Duration(seconds: 2));
        async.elapse(const Duration(seconds: 20));
      }

      // 只拽两次就收手,之后直接认下新时间轴,不再跟这条流对着 seek。
      expect(adapter.seeks, hasLength(2));
      expect(controller.state.position, const Duration(seconds: 2));
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('position jitter inside the tolerance is not mistaken for a reset',
      () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.positionController.add(const Duration(minutes: 12));

    adapter.positionController.add(const Duration(minutes: 11, seconds: 58));

    expect(adapter.seeks, isEmpty);
    expect(controller.state.position, const Duration(minutes: 11, seconds: 58));
    await controller.dispose();
  });

  test('seeking backwards on purpose is not treated as a reset', () async {
    final adapter = _FakePlayerAdapter();
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(const [_track480], _track480);
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.positionController.add(const Duration(minutes: 12));

    await controller.seekTo(const Duration(minutes: 1), resumeAfterSeek: false);
    adapter.positionController.add(const Duration(minutes: 1));
    adapter.positionController.add(const Duration(minutes: 1, seconds: 1));

    // 一次 seek,不是三次 —— 拽回去的逻辑不能跟用户对着干。
    expect(adapter.seeks, [const Duration(minutes: 1)]);
    expect(controller.state.position, const Duration(minutes: 1, seconds: 1));
    await controller.dispose();
  });

  test('a user seek supersedes a resume that has not landed yet', () async {
    final adapter = _FakePlayerAdapter()..dropStartAt = true;
    final controller = PlaybackSessionController(
      messages: _messages,
      player: adapter,
      tracks: _FakeTrackProvider(),
      delay: (_) async {},
    );
    await controller.start(
      const [_track480],
      _track480,
      initialPosition: const Duration(minutes: 12),
    );

    await controller.seekTo(const Duration(minutes: 2), resumeAfterSeek: false);
    adapter.positionController.add(const Duration(minutes: 2));
    // 断点恢复已经作废:时长到手也不该再把用户拽回 12 分钟。
    adapter.durationController.add(const Duration(minutes: 24));
    await Future<void>.delayed(Duration.zero);

    expect(adapter.seeks, [const Duration(minutes: 2)]);
    expect(controller.state.position, const Duration(minutes: 2));
    await controller.dispose();
  });
}
