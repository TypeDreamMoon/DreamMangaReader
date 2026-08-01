import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/novel_library_store.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/platform/reader_keys.dart';
import 'novel_document_view.dart';
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
  bool _showControls = true;
  bool _loading = true;
  bool _wakeActive = false;
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
      if (index >= 0) _chapterIndex = index;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadChapter());
  }

  Future<void> _loadChapter({NovelLocator? restore}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final chapter = _chapter;
    try {
      final document = await widget.loadDocument(chapter);
      if (!mounted || chapter.id != _chapter.id) return;
      await _controller.loadChapter(chapter.id, document, _preferences);
      final locator = restore ?? _library.progressFor(widget.libraryKey);
      if (locator != null && locator.chapterId == chapter.id) {
        await _controller.restoreLocator(locator);
      }
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  void _onCommand(NovelReaderCommand command) {
    switch (command) {
      case NovelReaderCommand.previous:
        _previous();
      case NovelReaderCommand.next:
        _next();
      case NovelReaderCommand.toggleControls:
        if (mounted) setState(() => _showControls = !_showControls);
    }
  }

  Future<void> _previous() async {
    if (await _controller.previousPage()) return;
    if (_chapterIndex == 0 || !mounted) return;
    setState(() => _chapterIndex--);
    await _loadChapter(
      restore: NovelLocator(chapterId: _chapter.id, fraction: 1),
    );
  }

  Future<void> _next() async {
    if (await _controller.nextPage()) return;
    if (_chapterIndex >= widget.chapters.length - 1 || !mounted) return;
    setState(() => _chapterIndex++);
    await _loadChapter(
      restore: NovelLocator(chapterId: _chapter.id),
    );
  }

  void _saveLocator(NovelLocator locator) {
    if (locator.chapterId.isEmpty) return;
    _library.saveProgress(widget.libraryKey, locator);
  }

  void _queuePreferences(NovelReaderPreferences preferences) {
    _settingsQueue = _settingsQueue.then((_) async {
      if (!mounted) return;
      final locator = await _controller.captureLocator();
      _preferences = preferences;
      _library.setPreferences(preferences);
      _setWakeLock(preferences.keepScreenOn);
      await _controller.applyPreferences(preferences);
      await Future<void>.delayed(const Duration(milliseconds: 32));
      await _controller.restoreLocator(locator);
      if (mounted) setState(() {});
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
      setState(() => _showControls = !_showControls);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openDirectory() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 640),
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
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ListTile(
                    selected: index == _chapterIndex,
                    leading: SizedBox(
                      width: 38,
                      child: Text('${index + 1}', textAlign: TextAlign.center),
                    ),
                    title: Text(chapter.title),
                    onTap: () => Navigator.pop(context, index),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (selected == null || selected == _chapterIndex || !mounted) return;
    setState(() => _chapterIndex = selected);
    await _loadChapter(
      restore: NovelLocator(chapterId: _chapter.id),
    );
  }

  void _openSettings() {
    showNovelReaderSettings(
      context: context,
      value: _preferences,
      onChanged: _queuePreferences,
    );
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
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
                color: scheme.surface,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded, size: 42),
                        const SizedBox(height: 12),
                        Text(
                          context.l10n.novel_readerLoadFailed('$_error'),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _loadChapter,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(context.l10n.retry),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            IgnorePointer(
              ignoring: !_showControls,
              child: AnimatedOpacity(
                opacity: _showControls ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Material(
                    color: scheme.surface.withValues(alpha: .96),
                    child: SafeArea(
                      bottom: false,
                      child: SizedBox(
                        height: 56,
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: context.l10n.novel_readerBack,
                              onPressed: () => Navigator.maybePop(context),
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.novel.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.titleSmall,
                                  ),
                                  Text(
                                    _chapter.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              key: const Key('novel-reader-directory'),
                              tooltip: context.l10n.novel_directory,
                              onPressed: _openDirectory,
                              icon: const Icon(
                                  Icons.format_list_bulleted_rounded),
                            ),
                            IconButton(
                              key: const Key('novel-reader-settings'),
                              tooltip: context.l10n.reader_settings,
                              onPressed: _openSettings,
                              icon: const Icon(Icons.text_fields_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IgnorePointer(
              ignoring: !_showControls,
              child: AnimatedOpacity(
                opacity: _showControls ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Material(
                    color: scheme.surface.withValues(alpha: .96),
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        height: 58,
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: context.l10n.novel_readerPreviousPage,
                              onPressed: _previous,
                              icon: const Icon(Icons.chevron_left_rounded),
                            ),
                            Expanded(
                              child: Text(
                                context.l10n.novel_readerProgress(
                                  _chapterIndex + 1,
                                  widget.chapters.length,
                                  _chapter.title,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                            ),
                            IconButton(
                              tooltip: context.l10n.novel_readerNextPage,
                              onPressed: _next,
                              icon: const Icon(Icons.chevron_right_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
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
