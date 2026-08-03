import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/platform/reader_keys.dart';
import '../../ui/ui.dart';
import 'novel_book_progress.dart';
import 'novel_document_view.dart';
import 'novel_reader_chrome.dart';
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

class _NovelReaderPageState extends State<NovelReaderPage> {
  static int _wakeCount = 0;

  late final NovelDocumentController _controller =
      widget.controller ?? WebNovelDocumentController();
  late final NovelLibraryStore _library = NovelLibraryScope.read(context);
  late NovelReaderPreferences _preferences = _library.preferences;
  late int _chapterIndex = widget.initialIndex;
  final FocusNode _focusNode = FocusNode(debugLabel: 'novel-reader');

  Future<void> _settingsQueue = Future.value();
  int _settingsGeneration = 0;
  Timer? _controlsTimer;
  bool _showControls = false;
  bool _controlsPaused = false;
  bool _loading = true;
  bool _wakeActive = false;
  double _chapterFraction = 0;
  double? _progressPreview;
  Object? _error;

  NovelChapter get _chapter => widget.chapters[_chapterIndex];

  @override
  void initState() {
    super.initState();
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
    _setWakeLock(_preferences.keepScreenOn);
    if (Platform.isAndroid) {
      ReaderKeys.setHandler((direction) {
        if (!mounted) return;
        direction > 0 ? _next() : _previous();
      });
      unawaited(ReaderKeys.setActive(true));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadChapter());
    });
  }

  Future<bool> _loadChapter({NovelLocator? restore}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
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
        _previous();
      case NovelReaderCommand.next:
        _next();
      case NovelReaderCommand.toggleControls:
        _toggleReaderControls();
    }
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
    );
    _hideReaderControls();
  }

  void _saveLocator(NovelLocator locator) {
    if (locator.chapterId.isEmpty) return;
    _library.saveProgress(widget.libraryKey, locator);
    if (mounted && locator.chapterId == _chapter.id) {
      setState(() => _chapterFraction = locator.fraction);
    }
  }

  void _queuePreferences(NovelReaderPreferences preferences) {
    if (!mounted) return;
    final generation = ++_settingsGeneration;
    _preferences = preferences;
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
      await _controller.restoreLocator(locator);
      if (!mounted || generation != _settingsGeneration) return;
      _scheduleControlsHide();
    }).catchError((_) {});
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
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      _previous();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _next();
      return KeyEventResult.handled;
    }
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
            _documentView(),
            if (_loading)
              const ColoredBox(
                color: Color(0x55000000),
                child: Center(child: CircularProgressIndicator()),
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
    _settingsGeneration++;
    _controlsTimer?.cancel();
    _controller.onCommand = null;
    _controller.onLocatorChanged = null;
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
