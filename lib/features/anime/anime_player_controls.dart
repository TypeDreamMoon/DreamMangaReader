import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';

/// 播放器底部控件。
///
/// **不画自己的底** —— 底交给外层那层渐变遮罩。以前这里铺了一块实心
/// `0xC9000000`,压在渐变上就是一道硬边:上面一块纯黑板、下面接着渐变,
/// 中间一条看得见的缝。
///
/// 也**只占一行**。上一集 / 下一集原本单独占一整行,两个字挤在左右两端、中间
/// 一大片空,和上面那块黑板拼在一起就是截图里那个怪样子。它们本来就是按钮,
/// 跟播放键放一排即可。
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
    this.onPrevEpisode,
    this.onNextEpisode,
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

  /// null = 没有上下集,按钮置灰而不是消失 —— 位置固定,换集时按钮不会跳。
  final VoidCallback? onPrevEpisode;
  final VoidCallback? onNextEpisode;

  @override
  State<AnimePlayerControls> createState() => _AnimePlayerControlsState();
}

class _AnimePlayerControlsState extends State<AnimePlayerControls> {
  Duration? _preview;
  bool _wasPlaying = false;
  bool _scrubbing = false;

  Duration get _visiblePosition => _preview ?? widget.position;

  double get _durationMs => widget.duration.inMilliseconds.toDouble();

  double get _sliderValue {
    if (_durationMs <= 0) return 0;
    return _visiblePosition.inMilliseconds.clamp(0, _durationMs).toDouble();
  }

  void _startScrub(double _) {
    _wasPlaying = widget.playing;
    setState(() => _scrubbing = true);
    widget.onScrubStart(_wasPlaying);
  }

  void _previewScrub(double value) {
    setState(() => _preview = Duration(milliseconds: value.round()));
  }

  void _commitScrub(double value) {
    final target = Duration(milliseconds: value.round());
    setState(() {
      _preview = null;
      _scrubbing = false;
    });
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
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _seekBar(enabled),
        SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 4),
              _button(
                tooltip: l10n.player_prevEpisode,
                icon: Icons.skip_previous_rounded,
                onPressed: widget.onPrevEpisode,
              ),
              _button(
                tooltip: widget.playing ? l10n.player_pause : l10n.player_play,
                icon: widget.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                onPressed: widget.onPlayPause,
                size: 26,
              ),
              _button(
                tooltip: l10n.player_nextEpisode,
                icon: Icons.skip_next_rounded,
                onPressed: widget.onNextEpisode,
              ),
              _button(
                tooltip: l10n.player_back10,
                icon: Icons.replay_10_rounded,
                onPressed: enabled ? () => _shortSeek(-10) : null,
              ),
              _button(
                tooltip: l10n.player_forward10,
                icon: Icons.forward_10_rounded,
                onPressed: enabled ? () => _shortSeek(10) : null,
              ),
              const SizedBox(width: 6),
              // 当前 / 总时长挨在一起。以前一个贴最左一个贴最右,宽屏上两个数字
              // 隔着大半个屏幕,想知道「还剩多久」得横扫一遍。
              Text(
                '${_format(_visiblePosition)} / ${_format(widget.duration)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (widget.buffering) ...[
                const SizedBox(width: 10),
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
              ],
              const Spacer(),
              _button(
                tooltip: l10n.player_options,
                icon: Icons.playlist_play_rounded,
                onPressed: widget.onOpenPanel,
              ),
              _button(
                tooltip: l10n.player_fullscreen,
                icon: Icons.fullscreen_rounded,
                onPressed: widget.onFullscreen,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ],
    );
  }

  /// 进度条。细、贴边、拖的时候变粗 —— Material 默认那套(胖圆点 + 粗轨)
  /// 在视频画面上像个表单控件,不像进度条。
  Widget _seekBar(bool enabled) {
    final scrubbing = _scrubbing;
    return SizedBox(
      height: 22,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: scrubbing ? 5 : 3,
          activeTrackColor: Theme.of(context).colorScheme.primary,
          inactiveTrackColor: Colors.white24,
          thumbColor: Theme.of(context).colorScheme.primary,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: scrubbing ? 8 : 5,
            elevation: 0,
            pressedElevation: 0,
          ),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          trackShape: const RectangularSliderTrackShape(),
          showValueIndicator: ShowValueIndicator.never,
        ),
        child: Slider(
          value: _sliderValue,
          min: 0,
          max: enabled ? _durationMs : 1,
          onChangeStart: enabled ? _startScrub : null,
          onChanged: enabled ? _previewScrub : null,
          onChangeEnd: enabled ? _commitScrub : null,
        ),
      ),
    );
  }

  Widget _button({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    double size = 22,
  }) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        color: Colors.white,
        disabledColor: Colors.white24,
        iconSize: size,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      );
}
