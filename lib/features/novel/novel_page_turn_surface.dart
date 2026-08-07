import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/novel/reader/novel_page_turn_controller.dart';
import '../../core/novel/reader/novel_page_turn_physics.dart';
import '../../core/novel/reader/novel_reader_models.dart';

class NovelPageTurnSurface extends StatefulWidget {
  const NovelPageTurnSurface({
    super.key,
    required this.mode,
    required this.state,
    required this.previousFrame,
    required this.currentFrame,
    required this.nextFrame,
    required this.pageBackColor,
    required this.onCommitted,
    this.settlement,
    this.onSettled,
  });

  final NovelPageTurnMode mode;
  final NovelTurnState state;
  final NovelTurnDecision? settlement;
  final NovelPageFrame? previousFrame;
  final NovelPageFrame currentFrame;
  final NovelPageFrame? nextFrame;
  final Color pageBackColor;
  final ValueChanged<NovelTurnDirection> onCommitted;
  final VoidCallback? onSettled;

  @override
  State<NovelPageTurnSurface> createState() => _NovelPageTurnSurfaceState();
}

class _NovelPageTurnSurfaceState extends State<NovelPageTurnSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  NovelTurnDecision? _handledSettlement;
  NovelTurnDecision? _activeSettlement;
  double _settlementProgress = 0;

  MemoryImage? _previousProvider;
  MemoryImage? _currentProvider;
  MemoryImage? _nextProvider;
  ui.Image? _previousImage;
  ui.Image? _currentImage;
  ui.Image? _nextImage;
  ui.FragmentProgram? _curlProgram;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this)
      ..addListener(() {
        if (mounted) setState(() => _settlementProgress = _animation.value);
      })
      ..addStatusListener(_handleAnimationStatus);
    _syncProviders();
    _loadCurlProgram();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSettlement());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheProviders();
    _resolveImages();
  }

  @override
  void didUpdateWidget(covariant NovelPageTurnSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previousFrame != widget.previousFrame ||
        oldWidget.currentFrame != widget.currentFrame ||
        oldWidget.nextFrame != widget.nextFrame) {
      _syncProviders();
      _precacheProviders();
      _resolveImages();
    }
    if (!identical(oldWidget.settlement, widget.settlement) ||
        oldWidget.state.phase != widget.state.phase ||
        _targetFrame(oldWidget) == null && _targetFrame(widget) != null) {
      _startSettlement();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  void _syncProviders() {
    _previousProvider = _provider(widget.previousFrame);
    _currentProvider = _provider(widget.currentFrame)!;
    _nextProvider = _provider(widget.nextFrame);
    _previousImage = null;
    _currentImage = null;
    _nextImage = null;
  }

  MemoryImage? _provider(NovelPageFrame? frame) {
    return frame == null ? null : MemoryImage(frame.bytes);
  }

  void _precacheProviders() {
    for (final provider in [
      _previousProvider,
      _currentProvider,
      _nextProvider,
    ]) {
      if (provider != null) {
        precacheImage(provider, context).catchError((_) {});
      }
    }
  }

  void _resolveImages() {
    _resolve(_previousProvider, (image) => _previousImage = image);
    _resolve(_currentProvider, (image) => _currentImage = image);
    _resolve(_nextProvider, (image) => _nextImage = image);
  }

  void _resolve(MemoryImage? provider, ValueChanged<ui.Image> assign) {
    if (provider == null) return;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) return;
        setState(() => assign(info.image));
      },
      onError: (_, __) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  Future<void> _loadCurlProgram() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/novel_page_curl.frag',
      );
      if (mounted) setState(() => _curlProgram = program);
    } catch (_) {
      // Canvas fallback remains interactive when runtime shaders are unavailable.
    }
  }

  NovelPageFrame? _targetFrame(NovelPageTurnSurface value) {
    return switch (value.state.direction) {
      NovelTurnDirection.previous => value.previousFrame,
      NovelTurnDirection.next => value.nextFrame,
      null => null,
    };
  }

  void _startSettlement() {
    if (!mounted || widget.state.phase != NovelTurnPhase.settling) return;
    final settlement = widget.settlement;
    if (settlement == null || identical(settlement, _handledSettlement)) return;
    final hasTarget = _targetFrame(widget) != null;
    if (settlement.commit && !hasTarget) return;

    _handledSettlement = settlement;
    _activeSettlement = settlement;
    final start = widget.state.progress.clamp(0.0, 1.0);
    final end = settlement.commit ? 1.0 : 0.0;
    _animation
      ..stop()
      ..duration = widget.mode == NovelPageTurnMode.none
          ? const Duration(milliseconds: 1)
          : settlement.duration
      ..value = start;
    _animation.animateTo(end, curve: Curves.easeOutCubic);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    final settlement = _activeSettlement;
    if (settlement == null) return;
    final finished = settlement.commit
        ? status == AnimationStatus.completed
        : status == AnimationStatus.dismissed;
    if (!finished) return;
    _activeSettlement = null;
    if (settlement.commit) widget.onCommitted(settlement.direction);
    widget.onSettled?.call();
  }

  double get _progress {
    if (widget.state.phase == NovelTurnPhase.settling &&
        identical(widget.settlement, _handledSettlement)) {
      return _settlementProgress;
    }
    return widget.state.progress.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final direction = widget.state.direction ?? NovelTurnDirection.next;
    final targetProvider = direction == NovelTurnDirection.next
        ? _nextProvider
        : _previousProvider;
    final targetImage =
        direction == NovelTurnDirection.next ? _nextImage : _previousImage;
    final progress = _targetFrame(widget) == null ? 0.0 : _progress;

    return ClipRect(
      key: Key('novel-turn-${widget.mode.name}'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return switch (widget.mode) {
            NovelPageTurnMode.curl => _buildCurl(
                size,
                direction,
                progress,
                targetProvider,
                targetImage,
              ),
            NovelPageTurnMode.cover => _buildCover(
                size,
                direction,
                progress,
                targetProvider,
              ),
            NovelPageTurnMode.translate => _buildTranslate(
                size,
                direction,
                progress,
                targetProvider,
              ),
            NovelPageTurnMode.none => _buildNone(progress, targetProvider),
            NovelPageTurnMode.scroll => _buildScroll(
                size,
                direction,
                progress,
                targetProvider,
              ),
          };
        },
      ),
    );
  }

  Widget _page(MemoryImage provider, Key key) {
    return SizedBox.expand(
      key: key,
      child: ColoredBox(
        color: widget.pageBackColor,
        child: Image(
          image: provider,
          fit: BoxFit.fill,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }

  Widget _target(MemoryImage? provider) {
    return provider == null
        ? const SizedBox.shrink()
        : _page(provider, const Key('novel-turn-target'));
  }

  Widget _current() {
    return _page(_currentProvider!, const Key('novel-turn-current'));
  }

  Widget _buildCurl(
    Size size,
    NovelTurnDirection direction,
    double progress,
    MemoryImage? targetProvider,
    ui.Image? targetImage,
  ) {
    final sign = direction == NovelTurnDirection.next ? -1.0 : 1.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (targetProvider != null) _target(targetProvider),
        Transform.translate(
          offset: Offset(sign * size.width * progress * .18, 0),
          child: _current(),
        ),
        if (_currentImage != null && targetImage != null)
          CustomPaint(
            painter: _NovelCurlPainter(
              program: _curlProgram,
              current: _currentImage!,
              target: targetImage,
              direction: direction,
              progress: progress,
              pageBackColor: widget.pageBackColor,
            ),
          ),
      ],
    );
  }

  Widget _buildCover(
    Size size,
    NovelTurnDirection direction,
    double progress,
    MemoryImage? targetProvider,
  ) {
    final sign = direction == NovelTurnDirection.next ? -1.0 : 1.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (targetProvider != null) _target(targetProvider),
        Transform.translate(
          offset: Offset(sign * size.width * progress, 0),
          child: _current(),
        ),
      ],
    );
  }

  Widget _buildTranslate(
    Size size,
    NovelTurnDirection direction,
    double progress,
    MemoryImage? targetProvider,
  ) {
    final sign = direction == NovelTurnDirection.next ? -1.0 : 1.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (targetProvider != null)
          Transform.translate(
            offset: Offset(sign * size.width * (progress - 1), 0),
            child: _target(targetProvider),
          ),
        Transform.translate(
          offset: Offset(sign * size.width * progress, 0),
          child: _current(),
        ),
      ],
    );
  }

  Widget _buildNone(double progress, MemoryImage? targetProvider) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (targetProvider != null)
          Opacity(
            opacity: progress >= 1 ? 1 : 0,
            child: _target(targetProvider),
          ),
        Opacity(
          opacity: targetProvider != null && progress >= 1 ? 0 : 1,
          child: _current(),
        ),
      ],
    );
  }

  Widget _buildScroll(
    Size size,
    NovelTurnDirection direction,
    double progress,
    MemoryImage? targetProvider,
  ) {
    final sign = direction == NovelTurnDirection.next ? -1.0 : 1.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (targetProvider != null)
          Transform.translate(
            offset: Offset(0, sign * size.height * (progress - 1)),
            child: _target(targetProvider),
          ),
        Transform.translate(
          offset: Offset(0, sign * size.height * progress),
          child: _current(),
        ),
      ],
    );
  }
}

class _NovelCurlPainter extends CustomPainter {
  const _NovelCurlPainter({
    required this.program,
    required this.current,
    required this.target,
    required this.direction,
    required this.progress,
    required this.pageBackColor,
  });

  final ui.FragmentProgram? program;
  final ui.Image current;
  final ui.Image target;
  final NovelTurnDirection direction;
  final double progress;
  final Color pageBackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fragmentProgram = program;
    if (fragmentProgram != null) {
      final shader = fragmentProgram.fragmentShader()
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, progress)
        ..setFloat(3, .5)
        ..setFloat(4, direction == NovelTurnDirection.next ? 1 : -1)
        ..setFloat(5, pageBackColor.r)
        ..setFloat(6, pageBackColor.g)
        ..setFloat(7, pageBackColor.b)
        ..setFloat(8, pageBackColor.a)
        ..setImageSampler(0, current)
        ..setImageSampler(1, target);
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      return;
    }

    final source = Rect.fromLTWH(
      0,
      0,
      current.width.toDouble(),
      current.height.toDouble(),
    );
    final targetSource = Rect.fromLTWH(
      0,
      0,
      target.width.toDouble(),
      target.height.toDouble(),
    );
    canvas.drawImageRect(target, targetSource, Offset.zero & size, Paint());
    final sign = direction == NovelTurnDirection.next ? -1.0 : 1.0;
    canvas.save();
    canvas.translate(sign * size.width * progress, 0);
    canvas.drawImageRect(current, source, Offset.zero & size, Paint());
    canvas.restore();

    final foldX = direction == NovelTurnDirection.next
        ? size.width * (1 - progress)
        : size.width * progress;
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(foldX, size.height / 2),
        width: 18,
        height: size.height,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: .16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  }

  @override
  bool shouldRepaint(covariant _NovelCurlPainter oldDelegate) {
    return oldDelegate.program != program ||
        oldDelegate.current != current ||
        oldDelegate.target != target ||
        oldDelegate.direction != direction ||
        oldDelegate.progress != progress ||
        oldDelegate.pageBackColor != pageBackColor;
  }
}
