import 'dart:async';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_session.dart';
import 'package:dream_manga_reader/features/anime/playback/media_kit_player_adapter.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_messages.dart';
import 'package:dream_manga_reader/features/anime/playback/subtitle_option.dart';
import 'package:flutter_test/flutter_test.dart';

const _hls = VideoTrack(
  url: 'https://media.example.test/master.m3u8',
  quality: '480p',
  headers: {'Authorization': 'Bearer private'},
  hls: true,
);

/// 文案用可辨认的英文占位:这层只关心「有没有把注入的文案透出去」。
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

class _FakeBackend implements MediaKitBackend {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final subtitleController =
      StreamController<List<SubtitleOption>>.broadcast(sync: true);
  final opened = <VideoTrack>[];
  final openStarts = <Duration>[];
  final configured = <VideoTrack>[];
  final attachedAudio = <String>[];
  final seeks = <Duration>[];
  final subtitles = <SubtitleOption>[];
  int clearedAudioCount = 0;
  Duration mediaDuration = Duration.zero;

  /// true = 下一次 open 抛错。用来把「网关回退也失败了」这条路走通。
  bool failOpen = false;

  @override
  Stream<bool> get playing => playingController.stream;
  @override
  Stream<bool> get buffering => bufferingController.stream;
  @override
  Stream<Duration> get position => positionController.stream;
  @override
  Stream<Duration> get durationChanges => const Stream.empty();
  @override
  Stream<bool> get completed => completedController.stream;
  @override
  Stream<Object> get errors => errorController.stream;
  @override
  Stream<Duration> get buffer => bufferController.stream;
  @override
  Stream<List<SubtitleOption>> get subtitleTracks => subtitleController.stream;
  @override
  Duration get duration => mediaDuration;

  @override
  Future<void> configure(VideoTrack track) async => configured.add(track);
  @override
  Future<void> open(VideoTrack track, {Duration startAt = Duration.zero}) async {
    opened.add(track);
    openStarts.add(startAt);
    if (failOpen) throw StateError('fixture open failure');
  }
  @override
  Future<void> attachAudio(String url) async => attachedAudio.add(url);
  @override
  Future<void> clearAudio() async => clearedAudioCount++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSubtitle(SubtitleOption option) async =>
      subtitles.add(option);
  @override
  Future<void> dispose() async {}
}

class _FakeGateway implements HlsSessionGateway {
  final sessions = <_FakeSession>[];

  @override
  Future<HlsSession> open(VideoTrack track, {required String authScope}) async {
    final session = _FakeSession(sessions.length);
    sessions.add(session);
    return session.value;
  }
}

class _FakeSession {
  _FakeSession(int index) {
    value = HlsSession(
      localUri: Uri.parse('http://127.0.0.1:4567/session/$index'),
      onClose: ({required bool discardCache}) async {
        discarded = discardCache;
        closes++;
      },
      onBuffer: buffers.add,
      onSeek: () => seekNotifications++,
    );
  }

  late final HlsSession value;
  final buffers = <Duration>[];
  int seekNotifications = 0;
  int closes = 0;
  bool discarded = false;
}

void main() {
  test('opens HLS through the gateway without forwarding private headers',
      () async {
    final backend = _FakeBackend();
    final gateway = _FakeGateway();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: gateway,
      authScope: 'source:test',
      messages: _messages,
    );

    await adapter.open(_hls);

    expect(backend.configured, [_hls]);
    expect(backend.opened.single.url, startsWith('http://127.0.0.1:4567/'));
    expect(backend.opened.single.headers, isNull);
    await adapter.dispose();
  });

  test('an ad break does not drag the gateway fallback back to the start',
      () async {
    final backend = _FakeBackend();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: _FakeGateway(),
      authScope: 'source:test',
      messages: _messages,
    );
    await adapter.open(_hls);
    backend.positionController.add(const Duration(minutes: 12));

    // 拼进来的广告段重置了 PTS,位置掉回片头 —— 观众还在 12 分钟。
    backend.positionController.add(Duration.zero);
    backend.positionController.add(const Duration(milliseconds: 40));

    backend.errorController.add(StateError('HTTP 502'));
    await Future<void>.delayed(Duration.zero);

    expect(backend.opened.last, _hls);
    expect(backend.openStarts.last, const Duration(minutes: 12));
    await adapter.dispose();
  });

  test('a gateway playback error falls back to the original HLS once',
      () async {
    final backend = _FakeBackend();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: _FakeGateway(),
      authScope: 'source:test',
      messages: _messages,
    );
    final surfaced = <Object>[];
    final subscription = adapter.errors.listen(surfaced.add);
    await adapter.open(_hls);
    backend.positionController.add(const Duration(seconds: 73));

    backend.errorController.add(StateError('HTTP 501'));
    await Future<void>.delayed(Duration.zero);
    expect(backend.opened.last, _hls);
    expect(backend.openStarts.last, const Duration(seconds: 73));
    expect(backend.seeks, isEmpty);
    expect(surfaced, isEmpty);

    backend.errorController.add(StateError('connection reset'));
    expect(surfaced, hasLength(1));
    await subscription.cancel();
    await adapter.dispose();
  });

  // 这一条会一路冒到「播放失败」框里,不能是写死在 core 层的一句中文。
  test('a dead gateway fallback reports the injected copy', () async {
    final backend = _FakeBackend();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: _FakeGateway(),
      authScope: 'source:test',
      messages: _messages,
    );
    final surfaced = <Object>[];
    final subscription = adapter.errors.listen(surfaced.add);
    await adapter.open(_hls);

    // 网关塌了 → 回退直连 → 直连也开不起来。
    backend.failOpen = true;
    backend.errorController.add(StateError('gateway gone'));
    await Future<void>.delayed(Duration.zero);

    expect('${surfaced.single}', contains('gateway fallback: '));
    expect('${surfaced.single}', contains('gateway gone'));
    await subscription.cancel();
    await adapter.dispose();
  });

  test('keeps direct DASH playback and attaches its audio after readiness',
      () async {
    const dash = VideoTrack(
      url: 'https://media.example.test/video.m4s',
      quality: '1080p',
      audioUrl: 'https://media.example.test/audio.m4s',
    );
    final backend = _FakeBackend()..mediaDuration = const Duration(minutes: 2);
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: _FakeGateway(),
      authScope: 'source:test',
      messages: _messages,
    );

    await adapter.open(dash);
    backend.playingController.add(true);
    await Future<void>.delayed(Duration.zero);

    expect(backend.opened, [dash]);
    expect(backend.attachedAudio, [dash.audioUrl]);
    await adapter.dispose();
  });

  test('HLS seek notifies the active gateway session before backend seek',
      () async {
    final backend = _FakeBackend();
    final gateway = _FakeGateway();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: gateway,
      authScope: 'source:test',
      messages: _messages,
    );
    await adapter.open(_hls);

    await adapter.seek(const Duration(minutes: 6));

    expect(gateway.sessions.single.seekNotifications, 1);
    expect(backend.seeks, [const Duration(minutes: 6)]);
    await adapter.dispose();
  });

  test('reports how far the buffer leads the playhead, not the buffer end',
      () async {
    final backend = _FakeBackend();
    final gateway = _FakeGateway();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: gateway,
      authScope: 'source:test',
      messages: _messages,
    );
    await adapter.open(_hls);

    // 播到 5 分钟、缓冲末端 5 分 04 秒 = 只领先 4 秒。递绝对位置的话网关会读成
    // 「领先 5 分钟」,预取刹车从此再也不生效。
    backend.positionController.add(const Duration(minutes: 5));
    backend.bufferController.add(const Duration(minutes: 5, seconds: 4));
    // 刚跳过去、缓冲末端还落在播放头后面 —— 领先量收敛到 0,不往下发负数。
    backend.bufferController.add(const Duration(minutes: 4));

    expect(
      gateway.sessions.single.buffers,
      [const Duration(seconds: 4), Duration.zero],
    );
    await adapter.dispose();
  });

  test('boundary recovery clears stale audio before reopening at target',
      () async {
    const dash = VideoTrack(
      url: 'https://media.example.test/video.m4s',
      quality: '1080p',
      audioUrl: 'https://media.example.test/audio.m4s',
    );
    final backend = _FakeBackend()..mediaDuration = const Duration(minutes: 20);
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: _FakeGateway(),
      authScope: 'source:test',
      messages: _messages,
    );
    await adapter.open(dash);
    backend.playingController.add(true);
    await Future<void>.delayed(Duration.zero);

    await adapter.rebuildDecoder(const Duration(minutes: 9));
    backend.playingController.add(true);
    await Future<void>.delayed(Duration.zero);

    expect(backend.clearedAudioCount, 1);
    expect(backend.opened, [dash, dash]);
    // 重建是「从 9 分钟开机」,不是开完再跳回去。
    expect(backend.openStarts, [Duration.zero, const Duration(minutes: 9)]);
    expect(backend.seeks, isEmpty);
    expect(backend.attachedAudio, [dash.audioUrl, dash.audioUrl]);
    await adapter.dispose();
  });

  test('gateway fallback clears stale external audio before direct reopen',
      () async {
    const hlsWithAudio = VideoTrack(
      url: 'https://media.example.test/master.m3u8',
      quality: '1080p',
      audioUrl: 'https://media.example.test/audio.m4s',
      hls: true,
    );
    final backend = _FakeBackend()..mediaDuration = const Duration(minutes: 20);
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: _FakeGateway(),
      authScope: 'source:test',
      messages: _messages,
    );
    await adapter.open(hlsWithAudio);
    backend.playingController.add(true);
    await adapter.seek(const Duration(minutes: 7));
    backend.positionController.add(Duration.zero);

    backend.errorController.add(StateError('gateway decoder boundary'));
    await Future<void>.delayed(Duration.zero);

    expect(backend.clearedAudioCount, 1);
    expect(backend.opened.last, hlsWithAudio);
    // 网关回退同理:位置跟着重开的那次 open 走,不再补一发会被吞掉的 seek。
    expect(backend.seeks, [const Duration(minutes: 7)]);
    expect(backend.openStarts.last, const Duration(minutes: 7));
    await adapter.dispose();
  });
}
