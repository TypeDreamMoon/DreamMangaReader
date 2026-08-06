import 'dart:async';

import '../../../core/source/models.dart';
import 'playback_state.dart';
import 'player_adapter.dart';

abstract interface class PlaybackTrackProvider {
  Future<List<VideoTrack>> refresh();

  VideoTrack? matchRefreshed(
    VideoTrack current,
    List<VideoTrack> refreshed,
  );

  VideoTrack? lowerQuality(
    VideoTrack current,
    List<VideoTrack> available,
  );

  VideoTrack? alternateLine(
    VideoTrack current,
    List<VideoTrack> available,
  );
}

typedef PlaybackDelay = Future<void> Function(Duration duration);

class PlaybackSessionController {
  PlaybackSessionController({
    required PlayerAdapter player,
    required PlaybackTrackProvider tracks,
    PlaybackDelay? delay,
    this.onProgress,
    this.onPaused,
    this.stallThreshold = const Duration(seconds: 8),
    this.stableResetThreshold = const Duration(seconds: 15),
  })  : _player = player,
        _tracks = tracks,
        _delay = delay ?? Future<void>.delayed {
    _subscriptions.addAll([
      _player.playing.listen(_onPlaying),
      _player.buffering.listen(_onBuffering),
      _player.position.listen(_onPosition),
      _player.duration.listen(_onDuration),
      _player.completed.listen(_onCompleted),
      _player.errors.listen(_onError),
    ]);
  }

  static const _backoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  final PlayerAdapter _player;
  final PlaybackTrackProvider _tracks;
  final PlaybackDelay _delay;
  final void Function(Duration position, Duration duration)? onProgress;
  final void Function()? onPaused;
  final Duration stallThreshold;
  final Duration stableResetThreshold;
  final _states = StreamController<PlaybackState>.broadcast(sync: true);
  final List<StreamSubscription<Object?>> _subscriptions = [];

  PlaybackState _state = const PlaybackState.idle();
  PlaybackState get state => _state;
  Stream<PlaybackState> get states => _states.stream;

  List<VideoTrack> _available = const [];
  VideoTrack? _selected;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int? _reportedPositionSecond;
  Timer? _stallTimer;
  Timer? _stableTimer;
  int _generation = 0;
  int _recoveryRound = 0;
  bool _recovering = false;
  bool _playing = false;
  bool _userPaused = false;
  bool _disposed = false;

  Future<void> start(
    List<VideoTrack> available,
    VideoTrack selected, {
    Duration initialPosition = Duration.zero,
  }) async {
    final generation = ++_generation;
    _cancelTimers();
    _recovering = false;
    _userPaused = false;
    _recoveryRound = 0;
    final knownDuration = _duration;
    _position = _resumePosition(initialPosition, knownDuration);
    _duration = Duration.zero;
    _reportedPositionSecond = null;
    _available = List.unmodifiable(available);
    _selected = selected;
    _emit(PlaybackState(
      phase: PlaybackPhase.resolving,
      position: _position,
      selectedTrack: selected,
    ));
    try {
      await _open(
        selected,
        generation: generation,
        resume: _position > Duration.zero,
      );
    } catch (error) {
      if (_isCurrent(generation)) await _recover(error, generation);
    }
  }

  void setUserPaused(bool paused) {
    _userPaused = paused;
    if (paused) {
      _stallTimer?.cancel();
      unawaited(_player.pause());
    }
  }

  void setManualQualityLocked(bool locked) {
    _emit(_state.copyWith(manualQualityLocked: locked));
  }

  Future<void> _open(
    VideoTrack track, {
    required int generation,
    required bool resume,
  }) async {
    if (!_isCurrent(generation)) return;
    _selected = track;
    _emit(_state.copyWith(
      phase: PlaybackPhase.opening,
      position: _position,
      duration: _duration,
      selectedTrack: track,
    ));
    await _player.open(track);
    if (!_isCurrent(generation)) return;
    if (resume && _position > Duration.zero) await _player.seek(_position);
  }

  void _onPlaying(bool playing) {
    if (_disposed) return;
    final wasPlaying = _playing;
    _playing = playing;
    if (!playing) {
      if (wasPlaying) onPaused?.call();
      return;
    }
    _stallTimer?.cancel();
    _emit(_state.copyWith(
      phase: PlaybackPhase.playing,
      position: _position,
      duration: _duration,
      selectedTrack: _selected,
    ));
    _stableTimer?.cancel();
    final generation = _generation;
    _stableTimer = Timer(stableResetThreshold, () {
      if (_isCurrent(generation) && _state.phase == PlaybackPhase.playing) {
        _recoveryRound = 0;
      }
    });
  }

  void _onBuffering(bool buffering) {
    if (_disposed || _userPaused) return;
    if (!buffering) {
      _stallTimer?.cancel();
      if (_playing && _state.phase == PlaybackPhase.buffering) {
        _emit(_state.copyWith(
          phase: PlaybackPhase.playing,
          position: _position,
          duration: _duration,
          selectedTrack: _selected,
        ));
      }
      return;
    }
    _emit(_state.copyWith(
      phase: PlaybackPhase.buffering,
      position: _position,
      duration: _duration,
      selectedTrack: _selected,
    ));
    _stallTimer?.cancel();
    final generation = _generation;
    _stallTimer = Timer(stallThreshold, () {
      if (_isCurrent(generation) && !_userPaused) {
        unawaited(_recover(StateError('播放缓冲超时'), generation));
      }
    });
  }

  void _onPosition(Duration position) {
    if (_disposed) return;
    _position = position;
    final second = position.inSeconds;
    if (_reportedPositionSecond == second) return;
    _reportedPositionSecond = second;
    onProgress?.call(
      Duration(seconds: second),
      Duration(seconds: _duration.inSeconds),
    );
  }

  void _onDuration(Duration duration) {
    if (_disposed) return;
    _duration = duration;
    _emit(_state.copyWith(duration: duration));
  }

  void _onCompleted(bool completed) {
    if (!completed || _disposed) return;
    _cancelTimers();
    _emit(_state.copyWith(
      phase: PlaybackPhase.idle,
      position: _position,
      duration: _duration,
      selectedTrack: _selected,
    ));
  }

  void _onError(Object error) {
    if (_disposed || _userPaused) return;
    unawaited(_recover(error, _generation));
  }

  Future<void> _recover(Object cause, int generation) async {
    if (_recovering || !_isCurrent(generation)) return;
    final current = _selected;
    if (current == null) return;
    _recovering = true;
    _cancelTimers();
    Object lastError = cause;
    try {
      for (var round = _recoveryRound; round < _backoff.length; round++) {
        _emit(_state.copyWith(
          phase: PlaybackPhase.recovering,
          position: _position,
          duration: _duration,
          attempt: round + 1,
          selectedTrack: _selected,
          message: '正在恢复播放（${round + 1}/3）',
        ));
        await _delay(_backoff[round]);
        if (!_isCurrent(generation)) return;

        final candidates = switch (round) {
          0 => <Future<VideoTrack?> Function()>[
              () async => _selected,
            ],
          1 => <Future<VideoTrack?> Function()>[
              () async {
                final refreshed = await _tracks.refresh();
                _available = List.unmodifiable(refreshed);
                return _selected == null
                    ? null
                    : _tracks.matchRefreshed(_selected!, _available);
              },
            ],
          _ => <Future<VideoTrack?> Function()>[
              () async => _state.manualQualityLocked || _selected == null
                  ? null
                  : _tracks.lowerQuality(_selected!, _available),
              () async => _selected == null
                  ? null
                  : _tracks.alternateLine(_selected!, _available),
            ],
        };

        for (final candidate in candidates) {
          if (!_isCurrent(generation)) return;
          try {
            final track = await candidate();
            if (track == null || !_isCurrent(generation)) continue;
            await _open(track, generation: generation, resume: true);
            if (!_isCurrent(generation)) return;
            _recoveryRound = round + 1;
            return;
          } catch (error) {
            lastError = error;
          }
        }
      }
      if (_isCurrent(generation)) {
        _emit(PlaybackState(
          phase: PlaybackPhase.failed,
          position: _position,
          duration: _duration,
          attempt: _backoff.length,
          selectedTrack: _selected,
          manualQualityLocked: _state.manualQualityLocked,
          message: '播放恢复失败：$lastError',
        ));
      }
    } finally {
      _recovering = false;
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Duration _resumePosition(Duration requested, Duration knownDuration) {
    if (requested <= Duration.zero) return Duration.zero;
    if (knownDuration > Duration.zero &&
        knownDuration - requested <= const Duration(seconds: 10)) {
      return Duration.zero;
    }
    return requested;
  }

  void _emit(PlaybackState next) {
    if (_disposed) return;
    _state = next;
    _states.add(next);
  }

  void _cancelTimers() {
    _stallTimer?.cancel();
    _stableTimer?.cancel();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelTimers();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _states.close();
    await _player.dispose();
  }
}
