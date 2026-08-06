import '../../../core/source/models.dart';

enum PlaybackPhase {
  idle,
  resolving,
  opening,
  playing,
  buffering,
  recovering,
  failed,
}

class PlaybackState {
  const PlaybackState({
    required this.phase,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.message,
    this.attempt = 0,
    this.selectedTrack,
    this.manualQualityLocked = false,
  });

  const PlaybackState.idle() : this(phase: PlaybackPhase.idle);

  final PlaybackPhase phase;
  final Duration position;
  final Duration duration;
  final String? message;
  final int attempt;
  final VideoTrack? selectedTrack;
  final bool manualQualityLocked;

  PlaybackState copyWith({
    PlaybackPhase? phase,
    Duration? position,
    Duration? duration,
    String? message,
    int? attempt,
    VideoTrack? selectedTrack,
    bool? manualQualityLocked,
  }) =>
      PlaybackState(
        phase: phase ?? this.phase,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        message: message,
        attempt: attempt ?? this.attempt,
        selectedTrack: selectedTrack ?? this.selectedTrack,
        manualQualityLocked: manualQualityLocked ?? this.manualQualityLocked,
      );
}
