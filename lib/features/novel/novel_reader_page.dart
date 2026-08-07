import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/novel/reader/novel_page_cache.dart';
import '../../core/novel/reader/novel_page_turn_controller.dart';
import '../../core/novel/reader/novel_page_turn_physics.dart';
import '../../core/novel/reader/novel_reader_models.dart';
import '../../core/platform/reader_keys.dart';
import '../../ui/ui.dart';
import 'novel_book_progress.dart';
import 'novel_document_view.dart';
import 'novel_page_turn_surface.dart';
import 'novel_reader_chrome.dart';
import 'novel_reader_input.dart';
import 'novel_reader_settings_sheet.dart';

typedef NovelDocumentLoader = Future<NovelDocument> Function(
  NovelChapter chapter,
);
typedef NovelDocumentViewBuilder = Widget Function(
  BuildContext context,
  NovelDocumentController controller,
);

class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.novel,
    required this.chapters,
    required this.initialIndex,
    required this.libraryKey,
    required this.loadDocument,
    this.controller,
    this.documentViewBuilder,
  }) : assert(initialIndex >= 0 && initialIndex < chapters.length);

  final Novel novel;
  final List<NovelChapter> chapters;
  final int initialIndex;
  final String libraryKey;
  final NovelDocumentLoader loadDocument;
  final NovelDocumentController? controller;
  final NovelDocumentViewBuilder? documentViewBuilder;

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage>
    with WidgetsBindingObserver {
  static int _wakeCount = 0;

  late final NovelDocumentController _controller =
      widget.controller ?? WebNovelDocumentController();
  late final NovelLibraryStore _library = NovelLibraryScope.read(context);
  late NovelReaderPreferences _preferences = _library.preferences;
  late int _chapterIndex = widget.initialIndex;
  final FocusNode _focusNode = FocusNode(debugLabel: 'novel-reader');
  final NovelPageTurnController _turnController = NovelPageTurnController();
  late final NovelPageCache _pageCache = NovelPageCache(
    byteBudget: Platform.isAndroid ? 48 * 1024 * 1024 : 96 * 1024 * 1024,
  );

  Future<void> _settingsQueue = Future.value();
  int _settingsGeneration = 0;
  Timer? _controlsTimer;
  bool _showControls = false;
  bool _controlsPaused = false;
  bool _loading = true;
  bool _wakeActive = false;
  bool _captureActive = false;
  bool _retainFrameWhileLoading = false;
  double _chapterFraction = 0;
  double? _progressPreview;
  Object? _error;
  NovelSelection? _selection;
  NovelPageMetrics? _pageMetrics;
  NovelPageFrame? _previousFrame;
  NovelPageFrame? _currentFrame;
  NovelPageFrame? _nextFrame;
  NovelTurnState _turnState = const NovelTurnState.idle();
  NovelTurnDecision? _settlement;
  int _pageGeneration = 0;

  NovelChapter get _chapter => widget.chapters[_chapterIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final saved = _library.progressFor(widget.libraryKey);
    if (saved != null) {
      final index = widget.chapters.indexWhere(
        (chapter) => chapter.id == saved.chapterId,
      );
      if (index >= 0) {
        _chapterIndex = index;
        _chapterFraction = saved.fraction;
      }
    }
    _controller.onCommand = _onCommand;
    _controller.onLocatorChanged = _saveLocator;
    _controller.onSelectionChanged = _onSelectionChanged;
    _controller.onCaptureStateChanged = _onCaptureStateChanged;
    final webController = _controller;
    if (webController is WebNovelDocumentController) {
      webController.onFontFallback = _onFontFallback;
      webController.onRecoverableError = _showRecoverableReaderError;
    }
    _setWakeLock(_preferences.keepScreenOn);
    if (Platform.isAndroid) {
      ReaderKeys.setHandler((direction) {
        if (!mounted) return;
        _requestDiscrete(
          direction > 0 ? NovelTurnDirection.next : NovelTurnDirection.previous,
        );
      });
      unawaited(ReaderKeys.setActive(true));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadChapter());
    });
  }

  Future<bool> _loadChapter({
    NovelLocator? restore,
    bool retainCurrentFrame = false,
  }) async {
    final pageGeneration = ++_pageGeneration;
    _turnController.cancel();
    final retainFrame = retainCurrentFrame && _currentFrame != null;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _pageMetrics = null;
        _retainFrameWhileLoading = retainFrame;
        if (!retainFrame) {
          _previousFrame = null;
          _currentFrame = null;
          _nextFrame = null;
        }
        _turnState = _turnController.state;
        _settlement = null;
      });
    }
    final chapter = _chapter;
    try {
      final document = await widget.loadDocument(chapter);
      if (!mounted || chapter.id != _chapter.id) return false;
      await _controller.loadChapter(chapter.id, document, _preferences);
      final locator = restore ?? _library.progressFor(widget.libraryKey);
      if (locator != null && locator.chapterId == chapter.id) {
        await _controller.restoreLocator(locator);
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _chapterFraction =
              locator?.chapterId == chapter.id ? locator!.fraction : 0;
        });
        unawaited(
          _primePageFrames(chapter.id, pageGeneration).whenComplete(() {
            if (_pageRequestIsCurrent(chapter.id, pageGeneration) &&
                _retainFrameWhileLoading) {
              setState(() => _retainFrameWhileLoading = false);
            }
          }),
        );
      }
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _loading = false;
        _error = error;
      });
      return false;
    }
  }

  Future<void> _primePageFrames(String chapterId, int generation) async {
    if (_preferences.turnMode == NovelPageTurnMode.scroll) return;
    final metrics = await _waitForPageMetrics(chapterId, generation);
    if (metrics == null) return;
    final current = await _controller.capturePage(metrics.currentPageIndex);
    if (!_pageRequestIsCurrent(chapterId, generation) || current == null) {
      return;
    }
    _pageCache
      ..invalidateLayout(metrics.layoutFingerprint)
      ..put(current)
      ..pinCurrent(current.key)
      ..invalidateLayout(metrics.layoutFingerprint);

    NovelPageFrame? previous;
    NovelPageFrame? next;
    if (metrics.currentPageIndex > 0) {
      previous = await _controller.capturePage(metrics.currentPageIndex - 1);
      if (previous != null) _pageCache.put(previous);
    }
    if (metrics.currentPageIndex < metrics.pageCount - 1) {
      next = await _controller.capturePage(metrics.currentPageIndex + 1);
      if (next != null) _pageCache.put(next);
    }
    if (!_pageRequestIsCurrent(chapterId, generation)) return;
    setState(() {
      _pageMetrics = metrics;
      _previousFrame = previous;
      _currentFrame = current;
      _nextFrame = next;
      _retainFrameWhileLoading = false;
    });
    _prefetchBoundaryDocuments(metrics);
  }

  Future<NovelPageMetrics?> _waitForPageMetrics(
    String chapterId,
    int generation,
  ) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!_pageRequestIsCurrent(chapterId, generation)) return null;
      final metrics = await _controller.pageMetrics();
      if (metrics.layoutFingerprint.isNotEmpty &&
          metrics.viewport.width > 0 &&
          metrics.viewport.height > 0) {
        return metrics;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  bool _pageRequestIsCurrent(String chapterId, int generation) {
    return mounted && generation == _pageGeneration && chapterId == _chapter.id;
  }

  void _prefetchBoundaryDocuments(NovelPageMetrics metrics) {
    if (metrics.currentPageIndex <= 1 && _chapterIndex > 0) {
      unawaited(
        widget
            .loadDocument(widget.chapters[_chapterIndex - 1])
            .then<void>((_) {})
            .catchError((_) {}),
      );
    }
    if (metrics.currentPageIndex >= metrics.pageCount - 2 &&
        _chapterIndex < widget.chapters.length - 1) {
      unawaited(
        widget
            .loadDocument(widget.chapters[_chapterIndex + 1])
            .then<void>((_) {})
            .catchError((_) {}),
      );
    }
  }

  void _onSelectionChanged(NovelSelection? selection) {
    if (mounted) setState(() => _selection = selection);
  }

  void _onCaptureStateChanged(bool active) {
    if (mounted && active != _captureActive) {
      setState(() => _captureActive = active);
    }
  }

  @override
  void didHaveMemoryPressure() {
    _pageCache.shrinkForMemoryPressure();
    if (!mounted) return;
    setState(() {
      final currentKey = _currentFrame?.key;
      if (currentKey != null) {
        _currentFrame = _pageCache.get(currentKey);
      }
      _previousFrame = null;
      _nextFrame = null;
    });
  }

  double get _bookProgress => novelBookProgress(
        chapterIndex: _chapterIndex,
        chapterFraction: _chapterFraction,
        chapterCount: widget.chapters.length,
      );

  void _showReaderControls() {
    _controlsTimer?.cancel();
    if (!mounted) return;
    if (!_showControls) setState(() => _showControls = true);
    _scheduleControlsHide();
  }

  void _hideReaderControls() {
    _controlsTimer?.cancel();
    if (mounted && _showControls) setState(() => _showControls = false);
  }

  void _toggleReaderControls() {
    if (_showControls) {
      _hideReaderControls();
    } else {
      _showReaderControls();
    }
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    final seconds = _preferences.toolbarAutoHideSeconds;
    if (!_showControls || _controlsPaused || seconds == 0) return;
    _controlsTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_controlsPaused) {
        setState(() => _showControls = false);
      }
    });
  }

  void _pauseControls() {
    _controlsTimer?.cancel();
    _controlsPaused = true;
  }

  void _resumeControls() {
    _controlsPaused = false;
    if (!mounted) return;
    _focusNode.requestFocus();
    _showReaderControls();
  }

  void _onCommand(NovelReaderCommand command) {
    switch (command) {
      case NovelReaderCommand.previous:
        _requestDiscrete(NovelTurnDirection.previous);
      case NovelReaderCommand.next:
        _requestDiscrete(NovelTurnDirection.next);
      case NovelReaderCommand.toggleControls:
        _toggleReaderControls();
    }
  }

  void _onInputStateChanged() {
    if (mounted) setState(() => _turnState = _turnController.state);
  }

  void _onTurnDecision(NovelTurnDecision decision) {
    if (!mounted) return;
    setState(() {
      _turnState = _turnController.state;
      _settlement = decision;
    });
    if (decision.commit && _targetFrame(decision.direction) == null) {
      unawaited(_prepareMissingTarget(decision.direction));
    }
  }

  void _requestDiscrete(NovelTurnDirection direction) {
    if (_loading || _error != null || _selection != null || _controlsPaused) {
      return;
    }
    if (_preferences.turnMode == NovelPageTurnMode.scroll ||
        _currentFrame == null ||
        _pageMetrics == null) {
      unawaited(_legacyTurn(direction));
      return;
    }
    if (_turnController.state.phase != NovelTurnPhase.idle) {
      _turnController.queueDiscrete(direction);
      return;
    }
    if (_targetFrame(direction) == null) {
      unawaited(_prepareMissingTarget(direction, startDiscrete: true));
      return;
    }
    _startDiscrete(direction);
  }

  void _startDiscrete(NovelTurnDirection direction) {
    final decision = _turnController.startDiscrete(direction);
    setState(() {
      _turnState = _turnController.state;
      _settlement = decision;
    });
  }

  NovelPageFrame? _targetFrame(NovelTurnDirection direction) {
    return direction == NovelTurnDirection.next ? _nextFrame : _previousFrame;
  }

  Future<void> _prepareMissingTarget(
    NovelTurnDirection direction, {
    bool startDiscrete = false,
  }) async {
    final current = _currentFrame;
    final metrics = _pageMetrics;
    if (current == null || metrics == null) return;
    final targetIndex =
        current.key.pageIndex + (direction == NovelTurnDirection.next ? 1 : -1);
    if (targetIndex < 0 || targetIndex >= metrics.pageCount) {
      _turnController.cancel();
      if (mounted) {
        setState(() {
          _turnState = _turnController.state;
          _settlement = null;
        });
      }
      await _legacyTurn(direction);
      return;
    }
    final frame = await _controller.capturePage(targetIndex);
    if (!mounted) return;
    if (frame == null || frame.key.chapterId != _chapter.id) {
      _turnController.cancel();
      setState(() {
        _turnState = _turnController.state;
        _settlement = null;
      });
      return;
    }
    _pageCache.put(frame);
    setState(() {
      if (direction == NovelTurnDirection.next) {
        _nextFrame = frame;
      } else {
        _previousFrame = frame;
      }
    });
    if (startDiscrete && _turnController.state.phase == NovelTurnPhase.idle) {
      _startDiscrete(direction);
    }
  }

  Future<void> _legacyTurn(NovelTurnDirection direction) {
    return direction == NovelTurnDirection.next ? _next() : _previous();
  }

  void _onSurfaceSettled() {
    if (_settlement?.commit != false) return;
    _turnController.completeSettlement();
    final queued = _turnController.takeQueuedDirection();
    if (mounted) {
      setState(() {
        _turnState = _turnController.state;
        _settlement = null;
      });
    }
    if (queued != null) _requestDiscrete(queued);
  }

  Future<void> _onSurfaceCommitted(NovelTurnDirection direction) async {
    _turnController.completeSettlement();
    final committed = _turnController.consumeCommittedDirection();
    if (committed != direction) return;
    if (mounted) setState(() => _turnState = _turnController.state);
    final target = _targetFrame(direction);
    if (target == null) {
      _turnController.cancel();
      return;
    }
    try {
      await _controller.showPage(target.key.pageIndex);
      final locator = await _controller.captureLocator();
      if (!mounted || locator.chapterId != _chapter.id) {
        _turnController.cancel();
        if (mounted) {
          setState(() {
            _turnState = _turnController.state;
            _settlement = null;
          });
        }
        return;
      }
      final oldCurrent = _currentFrame;
      _pageCache.pinCurrent(target.key);
      _persistLocator(locator);
      _turnController.completeCommit();
      final queued = _turnController.takeQueuedDirection();
      setState(() {
        _currentFrame = target;
        if (direction == NovelTurnDirection.next) {
          _previousFrame = oldCurrent;
          _nextFrame = null;
        } else {
          _nextFrame = oldCurrent;
          _previousFrame = null;
        }
        _pageMetrics = NovelPageMetrics(
          pageCount: _pageMetrics!.pageCount,
          currentPageIndex: target.key.pageIndex,
          viewport: _pageMetrics!.viewport,
          layoutFingerprint: target.key.layoutFingerprint,
        );
        _turnState = _turnController.state;
        _settlement = null;
      });
      _prefetchBoundaryDocuments(_pageMetrics!);
      unawaited(_refreshAdjacentFrame(direction));
      if (queued != null) _requestDiscrete(queued);
    } catch (_) {
      _turnController.cancel();
      if (mounted) {
        setState(() {
          _turnState = _turnController.state;
          _settlement = null;
        });
      }
    }
  }

  Future<void> _refreshAdjacentFrame(NovelTurnDirection direction) async {
    final current = _currentFrame;
    final metrics = _pageMetrics;
    if (current == null || metrics == null) return;
    final targetIndex =
        current.key.pageIndex + (direction == NovelTurnDirection.next ? 1 : -1);
    if (targetIndex < 0 || targetIndex >= metrics.pageCount) return;
    final cached = _pageCache.get(
      NovelPageKey(
        chapterId: current.key.chapterId,
        pageIndex: targetIndex,
        layoutFingerprint: current.key.layoutFingerprint,
      ),
    );
    final frame = cached ?? await _controller.capturePage(targetIndex);
    if (!mounted || frame == null || frame.key.chapterId != _chapter.id) return;
    _pageCache.put(frame);
    setState(() {
      if (direction == NovelTurnDirection.next) {
        _nextFrame = frame;
      } else {
        _previousFrame = frame;
      }
    });
  }

  Future<void> _previous() async {
    if (await _controller.previousPage()) {
      _hideReaderControls();
      return;
    }
    if (_chapterIndex == 0 || !mounted) return;
    setState(() {
      _chapterIndex--;
      _chapterFraction = 1;
      _progressPreview = null;
    });
    await _loadChapter(
      restore: NovelLocator(chapterId: _chapter.id, fraction: 1),
      retainCurrentFrame: _currentFrame != null,
    );
    _hideReaderControls();
  }

  Future<void> _next() async {
    if (await _controller.nextPage()) {
      _hideReaderControls();
      return;
    }
    if (_chapterIndex >= widget.chapters.length - 1 || !mounted) return;
    setState(() {
      _chapterIndex++;
      _chapterFraction = 0;
      _progressPreview = null;
    });
    await _loadChapter(
      restore: NovelLocator(chapterId: _chapter.id),
      retainCurrentFrame: _currentFrame != null,
    );
    _hideReaderControls();
  }

  void _saveLocator(NovelLocator locator) {
    if (_captureActive || _turnController.state.phase != NovelTurnPhase.idle) {
      return;
    }
    _persistLocator(locator);
  }

  void _persistLocator(NovelLocator locator) {
    if (locator.chapterId.isEmpty) return;
    _library.saveProgress(widget.libraryKey, locator);
    if (mounted && locator.chapterId == _chapter.id) {
      setState(() => _chapterFraction = locator.fraction);
    }
  }

  void _queuePreferences(NovelReaderPreferences preferences) {
    if (!mounted) return;
    final previousPreferences = _preferences;
    final generation = ++_settingsGeneration;
    _preferences = preferences;
    _retainFrameWhileLoading = _currentFrame != null;
    _library.setPreferences(preferences);
    _setWakeLock(preferences.keepScreenOn);
    setState(() {});
    _settingsQueue = _settingsQueue.then((_) async {
      if (!mounted || generation != _settingsGeneration) return;
      final locator = await _controller.captureLocator();
      if (!mounted || generation != _settingsGeneration) return;
      await _controller.applyPreferences(preferences);
      if (!mounted || generation != _settingsGeneration) return;
      await Future<void>.delayed(const Duration(milliseconds: 32));
      if (!mounted || generation != _settingsGeneration) return;
      if (preferences.fontFamily != previousPreferences.fontFamily) {
        final metrics = await _controller.pageMetrics();
        if (!mounted || generation != _settingsGeneration) return;
        if (metrics.visibleTextLength == 0) {
          await _controller.applyPreferences(previousPreferences);
          if (!mounted || generation != _settingsGeneration) return;
          _preferences = previousPreferences;
          _library.setPreferences(previousPreferences);
          _setWakeLock(previousPreferences.keepScreenOn);
          setState(() {});
          await _controller.restoreLocator(locator);
          if (!mounted || generation != _settingsGeneration) return;
          _showRecoverableReaderError('字体加载失败，已恢复上一字体。');
          _refreshPageFramesAfterLayout();
          _scheduleControlsHide();
          return;
        }
      }
      await _controller.restoreLocator(locator);
      if (!mounted || generation != _settingsGeneration) return;
      _refreshPageFramesAfterLayout();
      _scheduleControlsHide();
    }).catchError((_) {});
  }

  void _onFontFallback(String fontId) {
    if (!mounted || _preferences.fontFamily == fontId) return;
    final restored = _preferences.copyWith(fontFamily: fontId);
    _preferences = restored;
    _library.setPreferences(restored);
    setState(() {});
  }

  void _showRecoverableReaderError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _refreshPageFramesAfterLayout() {
    final generation = ++_pageGeneration;
    final chapterId = _chapter.id;
    if (_preferences.turnMode == NovelPageTurnMode.scroll) {
      setState(() {
        _pageMetrics = null;
        _previousFrame = null;
        _currentFrame = null;
        _nextFrame = null;
        _retainFrameWhileLoading = false;
      });
      return;
    }
    unawaited(
      _primePageFrames(chapterId, generation).whenComplete(() {
        if (_pageRequestIsCurrent(chapterId, generation) &&
            _retainFrameWhileLoading) {
          setState(() => _retainFrameWhileLoading = false);
        }
      }),
    );
  }

  void _setWakeLock(bool enabled) {
    if (enabled == _wakeActive) return;
    _wakeActive = enabled;
    if (enabled) {
      if (_wakeCount++ == 0) {
        unawaited(WakelockPlus.enable().catchError((_) {}));
      }
    } else if (--_wakeCount == 0) {
      unawaited(WakelockPlus.disable().catchError((_) {}));
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_showControls) {
        _hideReaderControls();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openDirectory() async {
    _pauseControls();
    int? selected;
    try {
      if (MediaQuery.sizeOf(context).width >= 700) {
        selected = await showGeneralDialog<int>(
          context: context,
          barrierDismissible: true,
          barrierLabel:
              MaterialLocalizations.of(context).modalBarrierDismissLabel,
          barrierColor: Colors.black54,
          transitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (context, _, __) => Align(
            alignment: Alignment.centerRight,
            child: SafeArea(
              child: SizedBox(
                key: const Key('novel-reader-directory-panel-wide'),
                width: 420,
                height: double.infinity,
                child: Material(
                  elevation: 12,
                  color: context.palette.surface,
                  child: _directoryPanel(context),
                ),
              ),
            ),
          ),
          transitionBuilder: (context, animation, _, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        );
      } else {
        final height = (MediaQuery.sizeOf(context).height * .82)
            .clamp(320, 640)
            .toDouble();
        selected = await showModalBottomSheet<int>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: SizedBox(
              key: const Key('novel-reader-directory-panel-narrow'),
              height: height,
              child: _directoryPanel(context),
            ),
          ),
        );
      }
    } finally {
      _resumeControls();
    }
    if (selected == null || selected == _chapterIndex || !mounted) return;
    setState(() {
      _chapterIndex = selected!;
      _chapterFraction = 0;
      _progressPreview = null;
    });
    await _loadChapter(
      restore: NovelLocator(chapterId: _chapter.id),
    );
  }

  Widget _directoryPanel(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.novel_directory,
                  style: TextStyle(
                    color: context.palette.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.chapters.length,
            itemBuilder: (context, index) {
              final chapter = widget.chapters[index];
              final previousVolume =
                  index == 0 ? null : widget.chapters[index - 1].volumeId;
              final showVolume = chapter.volumeId != null &&
                  chapter.volumeId != previousVolume;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showVolume)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(
                        chapter.volumeTitle ?? '',
                        style: TextStyle(
                          color: context.palette.accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ListTile(
                    selected: index == _chapterIndex,
                    leading: SizedBox(
                      width: 38,
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    title: Text(chapter.title),
                    onTap: () => Navigator.pop(context, index),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openSettings() async {
    _pauseControls();
    try {
      await showNovelReaderSettings(
        context: context,
        value: _preferences,
        onChanged: _queuePreferences,
      );
    } finally {
      _resumeControls();
    }
  }

  Future<void> _openTheme() async {
    _pauseControls();
    NovelReaderTheme? selected;
    try {
      selected = await showModalBottomSheet<NovelReaderTheme>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Wrap(
              runSpacing: 8,
              children: [
                for (final theme in NovelReaderTheme.values)
                  ListTile(
                    selected: theme == _preferences.theme,
                    leading: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _themeColor(theme),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: context.palette.line),
                      ),
                    ),
                    title: Text(_themeLabel(context, theme)),
                    trailing: theme == _preferences.theme
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.pop(context, theme),
                  ),
              ],
            ),
          ),
        ),
      );
    } finally {
      _resumeControls();
    }
    if (selected != null && selected != _preferences.theme) {
      _queuePreferences(_preferences.copyWith(theme: selected));
    }
  }

  void _onProgressChanged(double value) {
    if (mounted) setState(() => _progressPreview = value.clamp(0, 1));
  }

  void _onProgressChangeEnd(double value) {
    unawaited(_seekBookProgress(value));
  }

  Future<void> _seekBookProgress(double value) async {
    final previousIndex = _chapterIndex;
    final previousFraction = _chapterFraction;
    final captured = await _controller.captureLocator();
    if (!mounted) return;
    final previousLocator = captured.chapterId == _chapter.id
        ? captured
        : NovelLocator(
            chapterId: _chapter.id,
            fraction: previousFraction,
          );
    final target = novelProgressTarget(
      progress: value,
      chapterCount: widget.chapters.length,
    );
    final targetChapter = widget.chapters[target.chapterIndex];
    final targetLocator = NovelLocator(
      chapterId: targetChapter.id,
      fraction: target.chapterFraction,
    );
    setState(() {
      _chapterIndex = target.chapterIndex;
      _chapterFraction = target.chapterFraction;
      _progressPreview = null;
    });
    final loaded = await _loadChapter(restore: targetLocator);
    if (loaded) {
      _saveLocator(targetLocator);
      _hideReaderControls();
      return;
    }
    if (!mounted) return;
    setState(() {
      _chapterIndex = previousIndex;
      _chapterFraction = previousFraction;
      _progressPreview = null;
    });
    await _loadChapter(restore: previousLocator);
  }

  String _progressLabel(BuildContext context) {
    final value = _progressPreview ?? _bookProgress;
    final target = novelProgressTarget(
      progress: value,
      chapterCount: widget.chapters.length,
    );
    final chapter = widget.chapters[target.chapterIndex];
    return '${(value * 100).round()}%  '
        '${context.l10n.novel_readerProgress(
      target.chapterIndex + 1,
      widget.chapters.length,
      chapter.title,
    )}';
  }

  Widget _documentView() {
    final builder = widget.documentViewBuilder;
    if (builder != null) return builder(context, _controller);
    final controller = _controller;
    if (controller is WebNovelDocumentController) {
      return NovelDocumentView(controller: controller);
    }
    return Center(child: Text(context.l10n.novel_readerMissingRenderer));
  }

  bool get _showTurnSurface {
    return _currentFrame != null &&
        (_captureActive ||
            _retainFrameWhileLoading ||
            _turnState.phase == NovelTurnPhase.dragging ||
            _turnState.phase == NovelTurnPhase.settling ||
            _turnState.phase == NovelTurnPhase.committing);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            NovelReaderInput(
              controller: _turnController,
              blocked: _controlsPaused ||
                  _selection != null ||
                  _loading ||
                  _error != null,
              dragEnabled: _preferences.turnMode != NovelPageTurnMode.scroll,
              singleHandNext: _preferences.singleHandNext,
              onStateChanged: _onInputStateChanged,
              onDecision: _onTurnDecision,
              onDiscrete: _requestDiscrete,
              onToggleControls: _toggleReaderControls,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _documentView(),
                  if (_showTurnSurface)
                    NovelPageTurnSurface(
                      key: const Key('novel-page-turn-surface'),
                      mode: _preferences.turnMode,
                      state: _turnState,
                      settlement: _settlement,
                      previousFrame: _previousFrame,
                      currentFrame: _currentFrame!,
                      nextFrame: _nextFrame,
                      pageBackColor: _themeColor(_preferences.theme),
                      onCommitted: (direction) =>
                          unawaited(_onSurfaceCommitted(direction)),
                      onSettled: _onSurfaceSettled,
                    ),
                ],
              ),
            ),
            if (_loading && !_retainFrameWhileLoading)
              const ColoredBox(
                color: Color(0x55000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_retainFrameWhileLoading)
              const SafeArea(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      key: Key('novel-reader-edge-loading'),
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                ),
              ),
            if (_error != null)
              ColoredBox(
                // onDark:错误页盖在阅读画布上,读者可能正用夜间底色 —— 与漫画
                // 阅读器/播放器同款,用固定亮色而不是 palette 文字色。
                color: Colors.black.withValues(alpha: 0.86),
                child: AppErrorView(
                  onDark: true,
                  message: context.l10n.novel_readerLoadFailed('$_error'),
                  onRetry: _loadChapter,
                ),
              ),
            NovelReaderChrome(
              visible: _showControls,
              bookTitle: widget.novel.title,
              chapterTitle: _chapter.title,
              progress: _progressPreview ?? _bookProgress,
              previewLabel: _progressLabel(context),
              onBack: () => Navigator.maybePop(context),
              onDirectory: () => unawaited(_openDirectory()),
              onTheme: () => unawaited(_openTheme()),
              onSettings: () => unawaited(_openSettings()),
              onProgressChanged: _onProgressChanged,
              onProgressChangeEnd: _onProgressChangeEnd,
              onInteraction: _scheduleControlsHide,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settingsGeneration++;
    _controlsTimer?.cancel();
    _controller.onCommand = null;
    _controller.onLocatorChanged = null;
    _controller.onSelectionChanged = null;
    _controller.onCaptureStateChanged = null;
    final webController = _controller;
    if (webController is WebNovelDocumentController) {
      webController.onFontFallback = null;
      webController.onRecoverableError = null;
    }
    unawaited(_library.flushPending());
    if (Platform.isAndroid) {
      unawaited(ReaderKeys.setActive(false));
      ReaderKeys.clearHandler();
    }
    _setWakeLock(false);
    _focusNode.dispose();
    super.dispose();
  }
}

Color _themeColor(NovelReaderTheme theme) => switch (theme) {
      NovelReaderTheme.sepia => const Color(0xfff2e8cf),
      NovelReaderTheme.white => Colors.white,
      NovelReaderTheme.dark => const Color(0xff292b2f),
      NovelReaderTheme.black => const Color(0xff050505),
    };

String _themeLabel(BuildContext context, NovelReaderTheme theme) =>
    switch (theme) {
      NovelReaderTheme.sepia => context.l10n.novel_readerThemeSepia,
      NovelReaderTheme.white => context.l10n.novel_readerThemeWhite,
      NovelReaderTheme.dark => context.l10n.novel_readerThemeDark,
      NovelReaderTheme.black => context.l10n.novel_readerThemeBlack,
    };
