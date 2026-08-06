import 'dart:async';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_session.dart';
import 'package:dream_manga_reader/features/anime/playback/media_kit_player_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

const _hls = VideoTrack(
  url: 'https://media.example.test/master.m3u8',
  quality: '480p',
  headers: {'Authorization': 'Bearer private'},
  hls: true,
);

class _FakeBackend implements MediaKitBackend {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final opened = <VideoTrack>[];
  final configured = <VideoTrack>[];
  final attachedAudio = <String>[];
  final seeks = <Duration>[];
  Duration mediaDuration = Duration.zero;

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
  Duration get duration => mediaDuration;

  @override
  Future<void> configure(VideoTrack track) async => configured.add(track);
  @override
  Future<void> open(VideoTrack track) async => opened.add(track);
  @override
  Future<void> attachAudio(String url) async => attachedAudio.add(url);
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> setRate(double rate) async {}
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
      onClose: () async {},
      onBuffer: (_) {},
      onSeek: () => seekNotifications++,
    );
  }

  late final HlsSession value;
  int seekNotifications = 0;
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
    );

    await adapter.open(_hls);

    expect(backend.configured, [_hls]);
    expect(backend.opened.single.url, startsWith('http://127.0.0.1:4567/'));
    expect(backend.opened.single.headers, isNull);
    await adapter.dispose();
  });

  test('a gateway playback error falls back to the original HLS once',
      () async {
    final backend = _FakeBackend();
    final adapter = MediaKitPlayerAdapter(
      backend: backend,
      gateway: _FakeGateway(),
      authScope: 'source:test',
    );
    final surfaced = <Object>[];
    final subscription = adapter.errors.listen(surfaced.add);
    await adapter.open(_hls);
    backend.positionController.add(const Duration(seconds: 73));

    backend.errorController.add(StateError('HTTP 501'));
    await Future<void>.delayed(Duration.zero);
    expect(backend.opened.last, _hls);
    expect(backend.seeks.last, const Duration(seconds: 73));
    expect(surfaced, isEmpty);

    backend.errorController.add(StateError('connection reset'));
    expect(surfaced, hasLength(1));
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
    );
    await adapter.open(_hls);

    await adapter.seek(const Duration(minutes: 6));

    expect(gateway.sessions.single.seekNotifications, 1);
    expect(backend.seeks, [const Duration(minutes: 6)]);
    await adapter.dispose();
  });
}
