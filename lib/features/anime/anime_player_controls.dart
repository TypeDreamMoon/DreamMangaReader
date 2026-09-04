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
    this.buffered = Duration.zero,
    required this.playing,
    required this.buffering,
    required this.onPlayPause,
    required this.onScrubStart,
    required this.onSeek,
    this.onOpenPanel,
    required this.onFullscreen,
    this.fullscreen = false,
    this.onPrevEpisode,
    this.onNextEpisode,
    this.onEpisodes,
    this.onRate,
    this.onQuality,
    this.rateLabel = '',
    this.qualityLabel = '',
  });

  final Duration position;
  final Duration duration;

  /// 已经缓冲到哪儿。画在进度条上就是播放头前面那截白条 —— 一眼看出「还能往前拖
  /// 多少不用等」。一般只有一两分钟,不会缓完整集。
  final Duration buffered;

  final bool playing;
  final bool buffering;
  final VoidCallback onPlayPause;
  final ValueChanged<bool> onScrubStart;
  final void Function(Duration target, bool resumeAfterSeek) onSeek;
  final VoidCallback? onOpenPanel;

  /// null = 这个平台没有窗口全屏(移动端本来就占满屏),整个按钮不显示。
  final VoidCallback? onFullscreen;

  /// 当前是否已全屏 —— 图标要跟着变,否则用户看不出自己在哪个状态。
  final bool fullscreen;

  /// null = 没有上下集,按钮置灰而不是消失 —— 位置固定,换集时按钮不会跳。
  final VoidCallback? onPrevEpisode;
  final VoidCallback? onNextEpisode;

  // —— 右下角那三个文字按钮:选集 / 倍速 / 清晰度 ——
  //
  // 都在这一排,而不是藏进右上角的设置面板里:看番时最常改的就是这三样,
  // 每一样都值一个直接够得着的位置。null = 这一档不可用,整个按钮不显示。
  final VoidCallback? onEpisodes;
  final VoidCallback? onRate;
  final VoidCallback? onQuality;

  /// 当前倍速 / 清晰度的读数。空 = 用「倍速」「清晰度」这样的通名。
  final String rateLabel;
  final String qualityLabel;

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

  double get _bufferedValue {
    if (_durationMs <= 0) return 0;
    return widget.buffered.inMilliseconds.clamp(0, _durationMs).toDouble();
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

  /// 跳转步长故意不对称:后退小、前进大。等距的 ±10 会让人在两个点之间来回
  /// 弹 —— 退回去发现退多了,再前进又回到原处。90 秒是绝大多数番剧的 OP 长度,
  /// 一下按过去就是跳片头。
  static const _backSeconds = 5;
  static const _forwardSeconds = 15;
  static const _openingSeconds = 90;

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
        // 一排放不下时先撤跳片头那颗:它在 Shift+→ 上还有一份,而选集 / 倍速 /
        // 清晰度没有别的入口。挤成一团点不中,比少一颗按钮更糟。
        LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          return SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 4),
                _button(
                  tooltip: l10n.player_prevEpisode,
                  icon: Icons.skip_previous_rounded,
                  onPressed: widget.onPrevEpisode,
                ),
                _button(
                  tooltip:
                      widget.playing ? l10n.player_pause : l10n.player_play,
                  icon: widget.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: widget.onPlayPause,
                  size: 30,
                ),
                _button(
                  tooltip: l10n.player_nextEpisode,
                  icon: Icons.skip_next_rounded,
                  onPressed: widget.onNextEpisode,
                ),
                _seekButton(
                  tooltip: l10n.player_back5,
                  seconds: _backSeconds,
                  forward: false,
                  onPressed: enabled ? () => _shortSeek(-_backSeconds) : null,
                ),
                _seekButton(
                  tooltip: l10n.player_forward15,
                  seconds: _forwardSeconds,
                  forward: true,
                  onPressed:
                      enabled ? () => _shortSeek(_forwardSeconds) : null,
                ),
                if (!compact)
                  _seekButton(
                    tooltip: l10n.player_skipOpening,
                    seconds: _openingSeconds,
                    forward: true,
                    onPressed:
                        enabled ? () => _shortSeek(_openingSeconds) : null,
                  ),
                const SizedBox(width: 6),
                // 当前 / 总时长挨在一起。以前一个贴最左一个贴最右,宽屏上两个
                // 数字隔着大半个屏幕,想知道「还剩多久」得横扫一遍。
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
                if (widget.onEpisodes != null)
                  _textButton(l10n.player_tabEpisodes, widget.onEpisodes!),
                if (widget.onRate != null)
                  _textButton(
                    widget.rateLabel.isEmpty
                        ? l10n.player_speedShort
                        : widget.rateLabel,
                    widget.onRate!,
                  ),
                if (widget.onQuality != null)
                  _textButton(
                    widget.qualityLabel.isEmpty
                        ? l10n.player_tabQuality
                        : widget.qualityLabel,
                    widget.onQuality!,
                  ),
                if (widget.onFullscreen != null)
                  _button(
                    tooltip: widget.fullscreen
                        ? l10n.player_exitFullscreen
                        : l10n.player_fullscreen,
                    icon: widget.fullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    onPressed: widget.onFullscreen,
                  ),
                const SizedBox(width: 4),
              ],
            ),
          );
        }),
      ],
    );
  }

  /// 右下角那三个文字按钮。文字比图标好使:「1.5x」「1080P」把当前状态直接说
  /// 出来了,图标只能表示「这儿能改倍速」。
  Widget _textButton(String label, VoidCallback onPressed) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );

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
          // 缓冲条压在未播那段上:比它亮,比强调色暗,三层一眼分得开。
          secondaryActiveTrackColor: Colors.white38,
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
          secondaryTrackValue: enabled ? _bufferedValue : null,
          min: 0,
          max: enabled ? _durationMs : 1,
          onChangeStart: enabled ? _startScrub : null,
          onChanged: enabled ? _previewScrub : null,
          onChangeEnd: enabled ? _commitScrub : null,
        ),
      ),
    );
  }

  /// 跳转按钮:一圈箭头 + 中间的秒数,和 Material 自带的 replay_10 长一样。
  /// 自己拼是因为内置只给了 5 / 10 / 30 三个数字 —— 秒数该由手感定,不该由
  /// 图标库里恰好有哪几个数字定。
  Widget _seekButton({
    required String tooltip,
    required int seconds,
    required bool forward,
    required VoidCallback? onPressed,
  }) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        color: Colors.white,
        disabledColor: Colors.white24,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.standard,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        icon: SizedBox.square(
          dimension: 26,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.flip(
                flipX: !forward,
                child: const Icon(Icons.refresh_rounded, size: 26),
              ),
              Text(
                '$seconds',
                style: const TextStyle(
                  fontSize: 9.5,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _button({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    double size = 26,
  }) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        color: Colors.white,
        disabledColor: Colors.white24,
        iconSize: size,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.standard,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      );
}
