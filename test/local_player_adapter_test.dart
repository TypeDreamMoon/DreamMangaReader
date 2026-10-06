import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/anime/playback/media_kit_player_adapter.dart';
import 'package:dream_manga_reader/features/anime/playback/subtitle_option.dart';
import 'package:dream_manga_reader/features/local/local_player_adapter.dart';

/// 记下每一次后端调用,顺序敏感 —— 恢复流程的顺序本身就是要测的行为。
class _FakeBackend implements MediaKitBackend {
  final List<String> log = [];
  final List<StreamController<Object?>> _controllers = [];

  StreamController<T> _controller<T>() {
    final controller = StreamController<T>.broadcast();
    _controllers.add(controller);
    return controller;
  }

  late final _playing = _controller<bool>();
  late final _buffering = _controller<bool>();
  late final _position = _controller<Duration>();
  late final _duration = _controller<Duration>();
  late final _completed = _controller<bool>();
  late final _errors = _controller<Object>();
  late final _buffer = _controller<Duration>();
  late final _tracks = _controller<List<SubtitleOption>>();

  // 缓存在字段上:`StreamController.stream` 每次取都是新的包装对象,
  // 而本测试要断言「适配器转发的是后端那一条流」。
  late final Stream<bool> _playingStream = _playing.stream;
  late final Stream<bool> _bufferingStream = _buffering.stream;
  late final Stream<Duration> _positionStream = _position.stream;
  late final Stream<Duration> _durationStream = _duration.stream;
  late final Stream<bool> _completedStream = _completed.stream;
  late final Stream<Object> _errorsStream = _errors.stream;
  late final Stream<Duration> _bufferStream = _buffer.stream;
  late final Stream<List<SubtitleOption>> _tracksStream = _tracks.stream;

  @override
  Stream<bool> get playing => _playingStream;
  @override
  Stream<bool> get buffering => _bufferingStream;
  @override
  Stream<Duration> get position => _positionStream;
  @override
  Stream<Duration> get durationChanges => _durationStream;
  @override
  Stream<bool> get completed => _completedStream;
  @override
  Stream<Object> get errors => _errorsStream;
  @override
  Stream<Duration> get buffer => _bufferStream;
  @override
  Stream<List<SubtitleOption>> get subtitleTracks => _tracksStream;
  @override
  Duration get duration => const Duration(minutes: 42);

  @override
  Future<void> configure(VideoTrack track) async => log.add('configure');

  @override
  Future<void> open(VideoTrack track, {Duration startAt = Duration.zero}) async =>
      log.add('open:${track.url}@${startAt.inMilliseconds}');

  @override
  Future<void> attachAudio(String url) async => log.add('attachAudio:$url');
  @override
  Future<void> clearAudio() async => log.add('clearAudio');
  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');
  @override
  Future<void> play() async => log.add('play');
  @override
  Future<void> pause() async => log.add('pause');
  @override
  Future<void> setRate(double rate) async => log.add('setRate:$rate');
  @override
  Future<void> setVolume(double volume) async => log.add('setVolume:$volume');
  @override
  Future<void> setSubtitle(SubtitleOption option) async =>
      log.add('setSubtitle:${option.id}');
  @override
  Future<void> dispose() async => log.add('dispose');

  Future<void> close() async {
    for (final controller in _controllers) {
      await controller.close();
    }
  }
}

void main() {
  const track = VideoTrack(
    url: 'file:///F:/media/Show.S01E02.mkv',
    quality: '本地',
  );
  const externalSubtitle = SubtitleOption(
    id: 'file:///F:/media/Show.S01E02.zh.srt',
    label: '简体中文',
    url: 'file:///F:/media/Show.S01E02.zh.srt',
  );

  late _FakeBackend backend;
  late LocalPlayerAdapter adapter;

  setUp(() {
    backend = _FakeBackend();
    adapter = LocalPlayerAdapter(backend, track: track);
  });

  tearDown(() => backend.close());

  test('open 透传 startAt,且绝不调用 configure()', () async {
    await adapter.open(track, startAt: const Duration(seconds: 90));

    expect(backend.log, ['open:${track.url}@90000']);
    expect(backend.log, isNot(contains('configure')));
  });

  test('断点走 open(startAt:) 而不是 open 之后再 seek', () async {
    await adapter.open(track, startAt: const Duration(minutes: 5));

    expect(backend.log.first, startsWith('open:'));
    expect(backend.log.where((call) => call.startsWith('seek')), isEmpty);
  });

  test('rebuildDecoder 用当前 track 与断点位置重开', () async {
    await adapter.rebuildDecoder(const Duration(seconds: 30));

    expect(backend.log, ['open:${track.url}@30000']);
    expect(backend.log, isNot(contains('configure')));
  });

  test('open 之后换的是新 track,rebuildDecoder 重开的是新那条', () async {
    const next = VideoTrack(
      url: 'file:///F:/media/Show.S01E03.mkv',
      quality: '本地',
    );
    await adapter.open(next);
    await adapter.rebuildDecoder(const Duration(seconds: 12));

    expect(adapter.track, next);
    expect(backend.log, [
      'open:${next.url}@0',
      'open:${next.url}@12000',
    ]);
  });

  test('rebuildDecoder 之后外挂字幕被挂回去', () async {
    await adapter.setSubtitle(externalSubtitle);
    backend.log.clear();

    await adapter.rebuildDecoder(const Duration(seconds: 5));

    expect(backend.log, [
      'open:${track.url}@5000',
      'setSubtitle:${externalSubtitle.id}',
    ]);
  });

  test('rebuildDecoder 不恢复内嵌字幕轨道(旧轨道号在新流里指向别的东西)', () async {
    await adapter.setSubtitle(
      const SubtitleOption(id: '3', label: '流内轨道', language: 'zh'),
    );
    backend.log.clear();

    await adapter.rebuildDecoder(const Duration(seconds: 5));

    expect(backend.log, ['open:${track.url}@5000']);
  });

  test('换集(open)会清掉字幕选择', () async {
    await adapter.setSubtitle(externalSubtitle);
    const next = VideoTrack(url: 'file:///F:/media/Show.S01E03.mkv');
    await adapter.open(next);
    backend.log.clear();

    await adapter.rebuildDecoder(const Duration(seconds: 1));

    expect(
      backend.log.where((call) => call.startsWith('setSubtitle')),
      isEmpty,
    );
  });

  test('字幕挂不上不会把重开流程带崩', () async {
    final failing = _ThrowingSubtitleBackend();
    final failingAdapter = LocalPlayerAdapter(failing, track: track);
    // 第一次选择字幕是成功的(用户在菜单里点了一下),失败发生在重开时的恢复。
    await failingAdapter.setSubtitle(externalSubtitle);

    await failingAdapter.rebuildDecoder(const Duration(seconds: 3));

    expect(failing.log, [
      'setSubtitle:${externalSubtitle.id}',
      'open:${track.url}@3000',
      'setSubtitleFailed',
    ]);
  });

  test('8 条流原样转发给后端', () {
    expect(adapter.playing, same(backend.playing));
    expect(adapter.buffering, same(backend.buffering));
    expect(adapter.position, same(backend.position));
    expect(adapter.duration, same(backend.durationChanges));
    expect(adapter.buffer, same(backend.buffer));
    expect(adapter.completed, same(backend.completed));
    expect(adapter.errors, same(backend.errors));
    expect(adapter.subtitles, same(backend.subtitleTracks));
  });

  test('seek / play / pause / setRate / setVolume 全部透传', () async {
    await adapter.seek(const Duration(seconds: 7));
    await adapter.play();
    await adapter.pause();
    await adapter.setRate(1.5);
    await adapter.setVolume(80);

    expect(backend.log, ['seek:7000', 'play', 'pause', 'setRate:1.5', 'setVolume:80.0']);
  });

  test('dispose 幂等,后端只被释放一次', () async {
    await adapter.dispose();
    await adapter.dispose();

    expect(backend.log, ['dispose']);
  });
}

class _ThrowingSubtitleBackend extends _FakeBackend {
  int _subtitleCalls = 0;

  /// 只有**重开时的那次恢复**会失败,选择字幕本身是成功的。
  @override
  Future<void> setSubtitle(SubtitleOption option) async {
    _subtitleCalls++;
    if (_subtitleCalls == 1) {
      log.add('setSubtitle:${option.id}');
      return;
    }
    log.add('setSubtitleFailed');
    throw StateError('字幕挂不上');
  }
}
