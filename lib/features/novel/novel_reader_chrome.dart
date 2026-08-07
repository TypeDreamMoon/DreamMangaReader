import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';

enum _NovelReaderSecondaryCommand { search, theme, typography }

class NovelReaderChrome extends StatelessWidget {
  const NovelReaderChrome({
    super.key,
    required this.visible,
    required this.bookTitle,
    required this.chapterTitle,
    required this.progress,
    required this.previewLabel,
    required this.canPreviousChapter,
    required this.canNextChapter,
    required this.onBack,
    required this.onBookmark,
    required this.onMore,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.onDirectory,
    required this.onSearch,
    required this.onTheme,
    required this.onSettings,
    required this.onProgressChanged,
    required this.onProgressChangeEnd,
    required this.onInteraction,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final bool visible;
  final String bookTitle;
  final String chapterTitle;
  final double progress;
  final String previewLabel;
  final bool canPreviousChapter;
  final bool canNextChapter;
  final VoidCallback onBack;
  final VoidCallback onBookmark;
  final VoidCallback onMore;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final VoidCallback onDirectory;
  final VoidCallback onSearch;
  final VoidCallback onTheme;
  final VoidCallback onSettings;
  final ValueChanged<double> onProgressChanged;
  final ValueChanged<double> onProgressChangeEnd;
  final VoidCallback onInteraction;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        reverseDuration: const Duration(milliseconds: 150),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, .035),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        ),
        child: visible
            ? Stack(
                key: const ValueKey('novel-reader-chrome-visible'),
                fit: StackFit.expand,
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: _topBar(context),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _bottomBar(context),
                  ),
                ],
              )
            : const SizedBox.shrink(
                key: ValueKey('novel-reader-chrome-hidden'),
              ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return DecoratedBox(
      key: const Key('novel-reader-top-bar'),
      decoration: BoxDecoration(color: backgroundColor),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Row(
                children: [
                  _iconButton(
                    tooltip: context.l10n.novel_readerBack,
                    icon: Icons.arrow_back_rounded,
                    onPressed: onBack,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bookTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: foregroundColor,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: foregroundColor.withValues(alpha: .7),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _iconButton(
                    key: const Key('novel-reader-bookmark'),
                    tooltip: context.l10n.novel_readerBookmark,
                    icon: Icons.bookmark_border_rounded,
                    onPressed: onBookmark,
                  ),
                  _iconButton(
                    key: const Key('novel-reader-more'),
                    tooltip: context.l10n.novel_readerMore,
                    icon: Icons.more_horiz_rounded,
                    onPressed: onMore,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    return DecoratedBox(
      key: const Key('novel-reader-bottom-bar'),
      decoration: BoxDecoration(color: backgroundColor),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 92,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 720;
                  return Row(
                    children: [
                      _iconButton(
                        key: const Key('novel-reader-previous-chapter'),
                        tooltip: context.l10n.novel_readerPreviousChapter,
                        icon: Icons.skip_previous_rounded,
                        onPressed:
                            canPreviousChapter ? onPreviousChapter : null,
                      ),
                      Expanded(child: _progress(context)),
                      _iconButton(
                        key: const Key('novel-reader-next-chapter'),
                        tooltip: context.l10n.novel_readerNextChapter,
                        icon: Icons.skip_next_rounded,
                        onPressed: canNextChapter ? onNextChapter : null,
                      ),
                      _iconButton(
                        key: const Key('novel-reader-directory'),
                        tooltip: context.l10n.novel_directory,
                        icon: Icons.format_list_bulleted_rounded,
                        onPressed: onDirectory,
                      ),
                      if (compact)
                        _secondaryMenu(context)
                      else ...[
                        _iconButton(
                          key: const Key('novel-reader-search'),
                          tooltip: context.l10n.novel_readerSearch,
                          icon: Icons.search_rounded,
                          onPressed: onSearch,
                        ),
                        _iconButton(
                          key: const Key('novel-reader-theme'),
                          tooltip: context.l10n.novel_readerTheme,
                          icon: Icons.palette_outlined,
                          onPressed: onTheme,
                        ),
                        _iconButton(
                          key: const Key('novel-reader-settings'),
                          tooltip: context.l10n.reader_settings,
                          icon: Icons.text_fields_rounded,
                          onPressed: onSettings,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _progress(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: foregroundColor,
            inactiveTrackColor: foregroundColor.withValues(alpha: .3),
            thumbColor: foregroundColor,
            overlayColor: foregroundColor.withValues(alpha: .12),
          ),
          child: Slider(
            key: const Key('novel-reader-progress-slider'),
            value: progress.clamp(0, 1),
            semanticFormatterCallback: (value) =>
                context.l10n.novel_readerProgressPercent(
              (value * 100).round(),
            ),
            onChanged: (value) {
              onInteraction();
              onProgressChanged(value);
            },
            onChangeEnd: (value) {
              onInteraction();
              onProgressChangeEnd(value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            previewLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foregroundColor.withValues(alpha: .75),
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _secondaryMenu(BuildContext context) {
    return PopupMenuButton<_NovelReaderSecondaryCommand>(
      key: const Key('novel-reader-secondary-overflow'),
      tooltip: context.l10n.novel_readerMoreTools,
      color: backgroundColor,
      iconColor: foregroundColor,
      onOpened: onInteraction,
      onSelected: (command) {
        onInteraction();
        switch (command) {
          case _NovelReaderSecondaryCommand.search:
            onSearch();
          case _NovelReaderSecondaryCommand.theme:
            onTheme();
          case _NovelReaderSecondaryCommand.typography:
            onSettings();
        }
      },
      itemBuilder: (context) => [
        _menuItem(
          _NovelReaderSecondaryCommand.search,
          Icons.search_rounded,
          context.l10n.novel_readerSearch,
        ),
        _menuItem(
          _NovelReaderSecondaryCommand.theme,
          Icons.palette_outlined,
          context.l10n.novel_readerTheme,
        ),
        _menuItem(
          _NovelReaderSecondaryCommand.typography,
          Icons.text_fields_rounded,
          context.l10n.reader_settings,
        ),
      ],
    );
  }

  PopupMenuItem<_NovelReaderSecondaryCommand> _menuItem(
    _NovelReaderSecondaryCommand value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: foregroundColor),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: foregroundColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconButton({
    Key? key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed == null
          ? null
          : () {
              onInteraction();
              onPressed();
            },
      icon: Icon(icon, color: foregroundColor),
    );
  }
}

class NovelReaderStatusOverlay extends StatelessWidget {
  const NovelReaderStatusOverlay({
    super.key,
    required this.visible,
    required this.chapterTitle,
    required this.currentPage,
    required this.pageCount,
    required this.bookProgress,
    required this.now,
    required this.batteryLevel,
    required this.showChapterName,
    required this.showPageNumber,
    required this.showBookProgress,
    required this.showTime,
    required this.showBattery,
    required this.foregroundColor,
  });

  final bool visible;
  final String chapterTitle;
  final int currentPage;
  final int pageCount;
  final double bookProgress;
  final DateTime now;
  final int? batteryLevel;
  final bool showChapterName;
  final bool showPageNumber;
  final bool showBookProgress;
  final bool showTime;
  final bool showBattery;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final showBatteryValue = showBattery && batteryLevel != null;
    final hasLeading = showChapterName;
    final hasTrailing =
        showPageNumber || showBookProgress || showTime || showBatteryValue;
    if (!visible || (!hasLeading && !hasTrailing)) {
      return const SizedBox.shrink();
    }
    final style = TextStyle(
      color: foregroundColor.withValues(alpha: .82),
      fontSize: 11,
      height: 1.1,
      shadows: const [
        Shadow(color: Color(0x55000000), blurRadius: 2),
      ],
    );
    return IgnorePointer(
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 7),
            child: DefaultTextStyle(
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: Row(
                children: [
                  if (showChapterName)
                    Expanded(
                      child: Text(
                        chapterTitle,
                        key: const Key('novel-status-chapter'),
                      ),
                    )
                  else
                    const Spacer(),
                  if (showPageNumber)
                    _statusText(
                      const Key('novel-status-page'),
                      '${currentPage.clamp(1, pageCount < 1 ? 1 : pageCount)}/'
                      '${pageCount < 1 ? 1 : pageCount}',
                    ),
                  if (showBookProgress)
                    _statusText(
                      const Key('novel-status-progress'),
                      '${(bookProgress.clamp(0, 1) * 100).round()}%',
                    ),
                  if (showTime)
                    _statusText(
                      const Key('novel-status-time'),
                      '${_twoDigits(now.hour)}:${_twoDigits(now.minute)}',
                    ),
                  if (showBatteryValue)
                    _statusText(
                      const Key('novel-status-battery'),
                      '${batteryLevel!.clamp(0, 100)}%',
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusText(Key key, String value) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Text(value, key: key),
    );
  }
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
