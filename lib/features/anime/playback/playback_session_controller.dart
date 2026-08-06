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
  static const _seekConfirmationTolerance = Duration(seconds: 3);

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
  Duration _confirmedPosition = Duration.zero;
  Duration? _pendingSeekTarget;
  Duration _duration = Duration.zero;
  int? _reportedPositionSecond;
  Timer? _stallTimer;
  Timer? _stableTimer;
  int _generation = 0;
  int _seekGeneration = 0;
  int _recoveryRound = 0;
  bool _recovering = false;
  bool _playing = false;
  bool _userPaused = false;
  bool _resumeAfterSeek = false;
  bool _disposed = false;

  Duration get _recoveryPosition => _pendingSeekTarget ?? _confirmedPosition;

  Future<void> start(
    List<VideoTrack> available,
    VideoTrack selected, {
    Duration initialPosition = Duration.zero,
  }) async {
    final generation = ++_generation;
    _seekGeneration++;
    _cancelTimers();
    _recovering = false;
    _userPaused = false;
    _resumeAfterSeek = false;
    _pendingSeekTarget = null;
    _recoveryRound = 0;
    final knownDuration = _duration;
    _confirmedPosition = _resumePosition(initialPosition, knownDuration);
    _duration = Duration.zero;
    _reportedPositionSecond = null;
    _available = List.unmodifiable(available);
    _selected = selected;
    _emit(PlaybackState(
      phase: PlaybackPhase.resolving,
      position: _confirmedPosition,
      selectedTrack: selected,
    ));
    try {
      await _open(
        selected,
        generation: generation,
        resume: _confirmedPosition > Duration.zero,
      );
    } catch (error) {
      if (_isCurrent(generation)) await _recover(error, generation);
    }
  }

  void setUserPaused(bool paused) {
    _userPaused = paused;
    if (paused) {
      _resumeAfterSeek = false;
      _stallTimer?.cancel();
      unawaited(_player.pause());
    }
  }

  Future<void> seekTo(
    Duration target, {
    required bool resumeAfterSeek,
  }) async {
    if (_disposed || _selected == null) return;
    final bounded = target < Duration.zero
        ? Duration.zero
        : _duration > Duration.zero && target > _duration
            ? _duration
            : target;
    final seekGeneration = ++_seekGeneration;
    _pendingSeekTarget = bounded;
    _resumeAfterSeek = resumeAfterSeek;
    _stallTimer?.cancel();
    _stableTimer?.cancel();
    _emit(_state.copyWith(
      position: bounded,
      pendingSeekTarget: bounded,
      seeking: true,
    ));

    await _player.pause();
    if (_disposed || seekGeneration != _seekGeneration) return;
    await _player.seek(bounded);
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
    final resumePosition = _recoveryPosition;
    _emit(_state.copyWith(
      phase: PlaybackPhase.opening,
      position: resumePosition,
      duration: _duration,
      selectedTrack: track,
    ));
    await _player.open(track);
    if (!_isCurrent(generation)) return;
    final currentResumePosition = _recoveryPosition;
    if (resume && currentResumePosition > Duration.zero) {
      await _player.seek(currentResumePosition);
    }
  }

  void _onPlaying(bool playing) {
    if (_disposed) return;
    if (_pendingSeekTarget != null) {
      _playing = false;
      _stallTimer?.cancel();
      return;
    }
    final wasPlaying = _playing;
    _playing = playing;
    if (!playing) {
      if (wasPlaying) onPaused?.call();
      return;
    }
    _stallTimer?.cancel();
    _emit(_state.copyWith(
      phase: PlaybackPhase.playing,
      position: _confirmedPosition,
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
    if (_disposed) return;
    final pendingSeek = _pendingSeekTarget != null;
    if (_userPaused && !pendingSeek) {
      _stallTimer?.cancel();
      return;
    }
    if (!buffering) {
      _stallTimer?.cancel();
      if (pendingSeek) return;
      if (_playing && _state.phase == PlaybackPhase.buffering) {
        _emit(_state.copyWith(
          phase: PlaybackPhase.playing,
          position: _confirmedPosition,
          duration: _duration,
          selectedTrack: _selected,
        ));
      }
      return;
    }
    _emit(_state.copyWith(
      phase: PlaybackPhase.buffering,
      position: _recoveryPosition,
      duration: _duration,
      selectedTrack: _selected,
    ));
    _stallTimer?.cancel();
    final generation = _generation;
    _stallTimer = Timer(stallThreshold, () {
      if (_isCurrent(generation) &&
          (!_userPaused || _pendingSeekTarget != null)) {
        unawaited(_recover(StateError('播放缓冲超时'), generation));
      }
    });
  }

  void _onPosition(Duration position) {
    if (_disposed) return;
    final pendingTarget = _pendingSeekTarget;
    if (pendingTarget != null) {
      final distance = (position - pendingTarget).abs();
      if (distance > _seekConfirmationTolerance) return;

      final seekGeneration = _seekGeneration;
      final shouldResume = _resumeAfterSeek;
      _confirmedPosition = position;
      _pendingSeekTarget = null;
      _resumeAfterSeek = false;
      _emit(_state.copyWith(
        position: position,
        clearPendingSeekTarget: true,
        seeking: false,
      ));
      _reportProgress(position);
      if (shouldResume) {
        unawaited(_playAfterSeekConfirmation(seekGeneration));
      }
      return;
    }

    _confirmedPosition = position;
    _reportProgress(position);
  }

  void _reportProgress(Duration position) {
    final second = position.inSeconds;
    if (_reportedPositionSecond == second) return;
    _reportedPositionSecond = second;
    onProgress?.call(
      Duration(seconds: second),
      Duration(seconds: _duration.inSeconds),
    );
  }

  Future<void> _playAfterSeekConfirmation(int seekGeneration) async {
    if (_disposed || seekGeneration != _seekGeneration) return;
    await _player.play();
  }

  void _onDuration(Duration duration) {
    if (_disposed) return;
    _duration = duration;
    _emit(_state.copyWith(duration: duration));
  }

  void _onCompleted(bool completed) {
    if (!completed || _disposed || _pendingSeekTarget != null) return;
    _cancelTimers();
    _emit(_state.copyWith(
      phase: PlaybackPhase.idle,
      position: _confirmedPosition,
      duration: _duration,
      selectedTrack: _selected,
    ));
  }

  void _onError(Object error) {
    if (_disposed || (_userPaused && _pendingSeekTarget == null)) return;
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
          position: _recoveryPosition,
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
          position: _recoveryPosition,
          duration: _duration,
          attempt: _backoff.length,
          selectedTrack: _selected,
          manualQualityLocked: _state.manualQualityLocked,
          pendingSeekTarget: _pendingSeekTarget,
          seeking: _pendingSeekTarget != null,
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
    _seekGeneration++;
    _cancelTimers();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _states.close();
    await _player.dispose();
  }
}
