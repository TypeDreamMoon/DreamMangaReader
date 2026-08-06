import 'package:flutter/material.dart';

class AnimePlayerControls extends StatefulWidget {
  const AnimePlayerControls({
    super.key,
    required this.position,
    required this.duration,
    required this.playing,
    required this.buffering,
    required this.onPlayPause,
    required this.onScrubStart,
    required this.onSeek,
    required this.onOpenPanel,
    required this.onFullscreen,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final VoidCallback onPlayPause;
  final ValueChanged<bool> onScrubStart;
  final void Function(Duration target, bool resumeAfterSeek) onSeek;
  final VoidCallback onOpenPanel;
  final VoidCallback onFullscreen;

  @override
  State<AnimePlayerControls> createState() => _AnimePlayerControlsState();
}

class _AnimePlayerControlsState extends State<AnimePlayerControls> {
  Duration? _preview;
  bool _wasPlaying = false;

  Duration get _visiblePosition => _preview ?? widget.position;

  double get _durationMs => widget.duration.inMilliseconds.toDouble();

  double get _sliderValue {
    if (_durationMs <= 0) return 0;
    return _visiblePosition.inMilliseconds.clamp(0, _durationMs).toDouble();
  }

  void _startScrub(double _) {
    _wasPlaying = widget.playing;
    widget.onScrubStart(_wasPlaying);
  }

  void _previewScrub(double value) {
    setState(() => _preview = Duration(milliseconds: value.round()));
  }

  void _commitScrub(double value) {
    final target = Duration(milliseconds: value.round());
    setState(() => _preview = null);
    widget.onSeek(target, _wasPlaying);
  }

  void _shortSeek(int seconds) {
    final requested = widget.position + Duration(seconds: seconds);
    final target = requested < Duration.zero
        ? Duration.zero
        : widget.duration > Duration.zero && requested > widget.duration
            ? widget.duration
            : requested;
    widget.onSeek(target, widget.playing);
  }

  String _format(Duration value) {
    final total = value.inSeconds.clamp(0, 359999);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final minuteText = minutes.toString().padLeft(2, '0');
    final secondText = seconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minuteText:$secondText'
        : '$minuteText:$secondText';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.duration > Duration.zero;
    return SizedBox(
      height: 76,
      child: ColoredBox(
        color: const Color(0xC9000000),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 28,
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Text(
                        _format(_visiblePosition),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: _sliderValue,
                        min: 0,
                        max: enabled ? _durationMs : 1,
                        onChangeStart: enabled ? _startScrub : null,
                        onChanged: enabled ? _previewScrub : null,
                        onChangeEnd: enabled ? _commitScrub : null,
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        _format(widget.duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    _button(
                      tooltip: widget.playing ? '暂停' : '播放',
                      icon: widget.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      onPressed: widget.onPlayPause,
                    ),
                    _button(
                      tooltip: '后退 10 秒',
                      icon: Icons.replay_10_rounded,
                      onPressed: enabled ? () => _shortSeek(-10) : null,
                    ),
                    _button(
                      tooltip: '前进 10 秒',
                      icon: Icons.forward_10_rounded,
                      onPressed: enabled ? () => _shortSeek(10) : null,
                    ),
                    if (widget.buffering)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    const Spacer(),
                    _button(
                      tooltip: '播放选项',
                      icon: Icons.playlist_play_rounded,
                      onPressed: widget.onOpenPanel,
                    ),
                    _button(
                      tooltip: '全屏',
                      icon: Icons.fullscreen_rounded,
                      onPressed: widget.onFullscreen,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        color: Colors.white,
        disabledColor: Colors.white30,
        iconSize: 22,
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      );
}
