import 'dart:async';

import 'package:media_kit/media_kit.dart' hide VideoTrack;

import '../../../core/net/app_proxy.dart';
import '../../../core/source/models.dart';
import 'hls_cache_gateway.dart';
import 'hls_session.dart';
import 'mpv_network_options.dart';
import 'player_adapter.dart';
import 'subtitle_option.dart';

abstract interface class MediaKitBackend {
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<Duration> get durationChanges;
  Stream<bool> get completed;
  Stream<Object> get errors;
  Stream<Duration> get buffer;
  Stream<List<SubtitleOption>> get subtitleTracks;
  Duration get duration;

  Future<void> configure(VideoTrack track);
  Future<void> open(VideoTrack track);
  Future<void> attachAudio(String url);
  Future<void> clearAudio();
  Future<void> seek(Duration position);
  Future<void> play();
  Future<void> pause();
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> setSubtitle(SubtitleOption option);
  Future<void> dispose();
}

class NativeMediaKitBackend implements MediaKitBackend {
  NativeMediaKitBackend(this.player);

  final Player player;

  @override
  Stream<bool> get playing => player.stream.playing;
  @override
  Stream<bool> get buffering => player.stream.buffering;
  @override
  Stream<Duration> get position => player.stream.position;
  @override
  Stream<Duration> get durationChanges => player.stream.duration;
  @override
  Stream<bool> get completed => player.stream.completed;
  @override
  Stream<Object> get errors => player.stream.error;
  @override
  Stream<Duration> get buffer => player.stream.buffer;
  @override
  Duration get duration => player.state.duration;

  // mpv 的轨道表里混着 no/auto 两条伪轨道(=关闭/自动),那是选择动作不是字幕,
  // 列进去会变成两条点了没反应的空条目。
  @override
  Stream<List<SubtitleOption>> get subtitleTracks =>
      player.stream.tracks.map((tracks) => [
            for (final track in tracks.subtitle)
              if (track.id != 'no' && track.id != 'auto')
                SubtitleOption(
                  id: track.id,
                  label: track.title ?? track.language ?? '',
                  language: track.language,
                ),
          ]);

  @override
  Future<void> configure(VideoTrack track) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final options = MpvNetworkOptions.forTrack(track, proxy: AppProxy.current);
    await platform.waitForPlayerInitialization;

    Future<void> required(String key, String value) async {
      try {
        await platform.setProperty(
          key,
          value,
          waitForInitialization: false,
        );
      } catch (error) {
        throw StateError('无法配置播放器网络参数 $key: $error');
      }
    }

    await required('network-timeout', '${options.networkTimeoutSeconds}');
    await required('user-agent', options.userAgent);
    await required('http-proxy', options.httpProxy ?? '');
    await required('stream-lavf-o', options.streamLavf);
    await required('demuxer-lavf-o', options.demuxerLavf);
    try {
      await platform.setProperty('demuxer-readahead-secs', '20');
      await platform.setProperty('demuxer-max-bytes', '${64 * 1024 * 1024}');
    } on Object {
      // Buffer tuning is optional; network properties above are required.
    }
  }

  @override
  Future<void> open(VideoTrack track) => player.open(
        Media(track.url, httpHeaders: track.headers),
      );

  @override
  Future<void> attachAudio(String url) =>
      player.setAudioTrack(AudioTrack.uri(url));
  @override
  Future<void> clearAudio() => player.setAudioTrack(AudioTrack.auto());
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> setRate(double rate) => player.setRate(rate);
  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);

  @override
  Future<void> setSubtitle(SubtitleOption option) => player.setSubtitleTrack(
        option.isOff
            ? SubtitleTrack.no()
            : option.isExternal
                ? SubtitleTrack.uri(
                    option.url!,
                    title: option.label.isEmpty ? null : option.label,
                    language: option.language,
                  )
                : SubtitleTrack(option.id, option.label, option.language),
      );

  @override
  Future<void> dispose() => player.dispose();
}

class MediaKitPlayerAdapter implements PlayerAdapter {
  MediaKitPlayerAdapter({
    required MediaKitBackend backend,
    required HlsSessionGateway gateway,
    required this.authScope,
  })  : _backend = backend,
        _gateway = gateway {
    _subscriptions.add(_backend.errors.listen(_onBackendError));
    _subscriptions.add(_backend.playing.listen(_onPlaying));
    _subscriptions.add(_backend.buffer.listen(_onBuffer));
    _subscriptions.add(_backend.position.listen(_onPosition));
  }

  final MediaKitBackend _backend;
  final HlsSessionGateway _gateway;
  final String authScope;
  final _errorController = StreamController<Object>.broadcast(sync: true);
  final List<StreamSubscription<Object?>> _subscriptions = [];
  HlsSession? _session;
  VideoTrack? _originalTrack;
  SubtitleOption? _subtitle;
  String? _pendingAudioUrl;
  Timer? _audioTimer;
  bool _audioAttached = false;
  bool _directFallback = false;
  Duration _position = Duration.zero;
  bool _disposed = false;

  @override
  Stream<bool> get playing => _backend.playing;
  @override
  Stream<bool> get buffering => _backend.buffering;
  @override
  Stream<Duration> get position => _backend.position;
  @override
  Stream<Duration> get duration => _backend.durationChanges;
  @override
  Stream<bool> get completed => _backend.completed;
  @override
  Stream<Object> get errors => _errorController.stream;
  @override
  Stream<List<SubtitleOption>> get subtitles => _backend.subtitleTracks;

  @override
  Future<void> open(VideoTrack track) async {
    if (_originalTrack != null) await _resetAudioAttachment();
    await _closeSession();
    _position = Duration.zero;
    // 换集就把字幕选择清掉:上一集的轨道号在新的一集里指向别的东西。
    _subtitle = null;
    await _openTrack(track);
  }

  Future<void> _openTrack(VideoTrack track) async {
    _originalTrack = track;
    _pendingAudioUrl = track.audioUrl;
    _audioAttached = false;
    _directFallback = false;
    await _backend.configure(track);
    if (!track.hls) {
      await _backend.open(track);
      await _restoreSubtitle();
      return;
    }
    final session = await _gateway.open(track, authScope: authScope);
    _session = session;
    await _backend.open(VideoTrack(
      url: session.localUri.toString(),
      quality: track.quality,
      hls: true,
    ));
    await _restoreSubtitle();
  }

  /// 重开(换线路 / 自动恢复 / 网关回退)之后把字幕挂回去。
  ///
  /// 只补外挂字幕:它的标识就是 URL,换个流也还指向同一个文件。内嵌轨道的 id
  /// 是 mpv 按当前文件现编的,拿旧号去点新流是错的,宁可让它回到流自己的默认。
  Future<void> _restoreSubtitle() async {
    final subtitle = _subtitle;
    if (subtitle == null || !subtitle.isExternal) return;
    try {
      await _backend.setSubtitle(subtitle);
    } on Object {
      // 字幕挂不上不该把整个重开流程带崩 —— 画面比字幕重要。
    }
  }

  @override
  Future<void> rebuildDecoder(Duration resumePosition) async {
    final track = _originalTrack;
    if (track == null || _disposed) return;
    await _resetAudioAttachment();
    await _closeSession();
    await _openTrack(track);
    if (resumePosition > Duration.zero) await seek(resumePosition);
  }

  void _onBackendError(Object error) {
    if (_disposed) return;
    if (_session != null && !_directFallback && _originalTrack != null) {
      _directFallback = true;
      unawaited(_openDirectFallback(error));
      return;
    }
    _errorController.add(error);
  }

  Future<void> _openDirectFallback(Object originalError) async {
    final track = _originalTrack;
    if (track == null || _disposed) return;
    try {
      await _resetAudioAttachment();
      await _closeSession();
      _pendingAudioUrl = track.audioUrl;
      await _backend.configure(track);
      await _backend.open(track);
      await _restoreSubtitle();
      if (_position > Duration.zero) await _backend.seek(_position);
    } catch (error) {
      if (!_disposed) {
        _errorController.add(
          StateError('HLS 网关回退失败: $originalError; $error'),
        );
      }
    }
  }

  void _onPlaying(bool playing) {
    if (!playing || _disposed || _audioAttached) return;
    _tryAttachAudio();
  }

  void _tryAttachAudio() {
    final audio = _pendingAudioUrl;
    if (audio == null || audio.isEmpty || _audioAttached) return;
    if (_backend.duration > Duration.zero) {
      _audioAttached = true;
      unawaited(_backend.attachAudio(audio));
      return;
    }
    _audioTimer ??= Timer.periodic(const Duration(milliseconds: 700), (timer) {
      if (_disposed || _audioAttached) {
        timer.cancel();
        return;
      }
      if (_backend.duration > Duration.zero || timer.tick >= 8) {
        _audioAttached = true;
        unawaited(_backend.attachAudio(audio));
        timer.cancel();
      }
    });
  }

  void _onBuffer(Duration buffer) => _session?.reportBuffer(buffer);

  void _onPosition(Duration position) {
    if (position == Duration.zero && _position > Duration.zero) return;
    _position = position;
  }

  Future<void> _resetAudioAttachment() async {
    _audioTimer?.cancel();
    _audioTimer = null;
    _pendingAudioUrl = null;
    _audioAttached = false;
    await _backend.clearAudio();
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _session?.notifySeek();
    await _backend.seek(position);
  }

  @override
  Future<void> play() => _backend.play();
  @override
  Future<void> pause() => _backend.pause();
  @override
  Future<void> setRate(double rate) => _backend.setRate(rate);
  @override
  Future<void> setVolume(double volume) => _backend.setVolume(volume);

  @override
  Future<void> setSubtitle(SubtitleOption option) {
    _subtitle = option.isOff ? null : option;
    return _backend.setSubtitle(option);
  }

  Future<void> _closeSession() async {
    final session = _session;
    _session = null;
    await session?.close();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _audioTimer?.cancel();
    await _closeSession();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _errorController.close();
    await _backend.dispose();
  }
}
