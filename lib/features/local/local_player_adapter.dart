import 'dart:async';

import '../../core/source/models.dart';
import '../anime/playback/media_kit_player_adapter.dart';
import '../anime/playback/player_adapter.dart';
import '../anime/playback/subtitle_option.dart';

/// 本地播放的 [PlayerAdapter]:直接转发 [MediaKitBackend],不碰网络层。
///
/// 为什么不复用 `MediaKitPlayerAdapter`:那个类要 `HlsSessionGateway` +
/// `authScope`,它的 `_openTrack` 还会无条件调用 `backend.configure()`。本地文件
/// 既没有 HLS 会话,也不需要网络参数,更重要的是 `configure()` 在 mpv 初始化失败时
/// 会抛 `StateError('无法配置播放器网络参数 …')` —— 本地播放不该被这条路带崩。
///
/// 因此这里**只**做三件事:转发 8 条流、用 `open(startAt:)` 开机、按需挂字幕。
///
/// 断点必须走 `open(startAt:)`,不能 open 之后再 seek:libmpv 的 loadfile 是异步的,
/// open() 返回时文件常常还没打开,紧随其后的 seek 会被静默丢掉(见 player_adapter.dart:22-25)。
/// 这一点由 [rebuildDecoder] 沿用。
class LocalPlayerAdapter implements PlayerAdapter {
  /// [track] 可以不给:番剧播放页那条注入路径把轨道交给 [open],构造时还没有
  /// 任何文件 —— 那时 [rebuildDecoder] 没有可重开的东西,直接算恢复完成。
  LocalPlayerAdapter(this._backend, {VideoTrack? track}) : _track = track;

  final MediaKitBackend _backend;
  VideoTrack? _track;
  SubtitleOption? _subtitle;
  bool _disposed = false;

  /// 当前文件。恢复流程([rebuildDecoder])重开的就是它;还没 [open] 过时为 null。
  VideoTrack? get track => _track;

  @override
  Stream<bool> get playing => _backend.playing;
  @override
  Stream<bool> get buffering => _backend.buffering;
  @override
  Stream<Duration> get position => _backend.position;
  @override
  Stream<Duration> get duration => _backend.durationChanges;
  @override
  Stream<Duration> get buffer => _backend.buffer;
  @override
  Stream<bool> get completed => _backend.completed;
  @override
  Stream<Object> get errors => _backend.errors;
  @override
  Stream<List<SubtitleOption>> get subtitles => _backend.subtitleTracks;

  @override
  Future<void> open(VideoTrack track, {Duration startAt = Duration.zero}) async {
    _track = track;
    // 换集就把字幕选择清掉:上一集的轨道号在新的一集里指向别的东西。外挂字幕
    // 的标识是 URL,播放页在 open 之后重新点一次即可(规格 §6.5)。
    _subtitle = null;
    // 注意:这里**不**调用 _backend.configure()(规格 §6.2 第 1 条)。
    await _backend.open(track, startAt: startAt);
  }

  @override
  Future<void> rebuildDecoder(Duration resumePosition) async {
    if (_disposed) return;
    final track = _track;
    // 还没 open 过(番剧页的注入路径把轨道交给 open):没有可重开的东西。
    if (track == null) return;
    // 卡顿/回退后的重开同样是「从这个位置开机」,不是开完再跳回去。
    await _backend.open(track, startAt: resumePosition);
    await _restoreSubtitle();
  }

  @override
  Future<void> seek(Duration position) => _backend.seek(position);
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

  /// 重开之后把外挂字幕挂回去。
  ///
  /// 只补外挂字幕:它的标识就是文件 URL,换个流也还指向同一个文件;内嵌轨道的 id
  /// 是 mpv 按当前文件现编的,拿旧号去点新流是错的。
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
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _backend.dispose();
  }
}
