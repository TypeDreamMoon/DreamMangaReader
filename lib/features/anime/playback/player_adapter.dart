import '../../../core/source/models.dart';

abstract interface class PlayerAdapter {
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get completed;
  Stream<Object> get errors;

  Future<void> open(VideoTrack track);
  Future<void> rebuildDecoder(Duration resumePosition);
  Future<void> seek(Duration position);
  Future<void> play();
  Future<void> pause();
  Future<void> setRate(double rate);
  Future<void> dispose();
}
