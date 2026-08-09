import '../../../core/source/models.dart';
import 'subtitle_option.dart';

abstract interface class PlayerAdapter {
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get completed;
  Stream<Object> get errors;

  /// 流里**自带**的字幕轨道,换集/换线路后会重发。源另给的外挂字幕不走这条,
  /// 由播放页从 [VideoTrack.subtitles] 合进同一份列表。
  Stream<List<SubtitleOption>> get subtitles;

  Future<void> open(VideoTrack track);
  Future<void> rebuildDecoder(Duration resumePosition);
  Future<void> seek(Duration position);
  Future<void> play();
  Future<void> pause();
  Future<void> setRate(double rate);

  /// 0–100,跟 media_kit 一致。这是**应用内**音量,不动系统音量。
  Future<void> setVolume(double volume);

  Future<void> setSubtitle(SubtitleOption option);
  Future<void> dispose();
}
