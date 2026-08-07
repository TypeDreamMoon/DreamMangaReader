import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';

class NovelReaderChrome extends StatelessWidget {
  const NovelReaderChrome({
    super.key,
    required this.visible,
    required this.bookTitle,
    required this.chapterTitle,
    required this.progress,
    required this.previewLabel,
    required this.onBack,
    required this.onDirectory,
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
  final VoidCallback onBack;
  final VoidCallback onDirectory;
  final VoidCallback onTheme;
  final VoidCallback onSettings;
  final ValueChanged<double> onProgressChanged;
  final ValueChanged<double> onProgressChangeEnd;
  final VoidCallback onInteraction;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, -1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: DecoratedBox(
                decoration: BoxDecoration(color: backgroundColor),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: SizedBox(
                      height: 56,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 980),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: context.l10n.novel_readerBack,
                                onPressed: () {
                                  onInteraction();
                                  onBack();
                                },
                                icon: Icon(
                                  Icons.arrow_back_rounded,
                                  color: foregroundColor,
                                ),
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
                                        color: foregroundColor.withValues(
                                          alpha: .7,
                                        ),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: DecoratedBox(
                key: const Key('novel-reader-bottom-bar'),
                decoration: BoxDecoration(color: backgroundColor),
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 84,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 980),
                        child: Row(
                          children: [
                            IconButton(
                              key: const Key('novel-reader-directory'),
                              tooltip: context.l10n.novel_directory,
                              onPressed: () {
                                onInteraction();
                                onDirectory();
                              },
                              icon: Icon(
                                Icons.format_list_bulleted_rounded,
                                color: foregroundColor,
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: foregroundColor,
                                      inactiveTrackColor:
                                          foregroundColor.withValues(alpha: .3),
                                      thumbColor: foregroundColor,
                                      overlayColor: foregroundColor.withValues(
                                          alpha: .12),
                                    ),
                                    child: Slider(
                                      key: const Key(
                                        'novel-reader-progress-slider',
                                      ),
                                      value: progress.clamp(0, 1),
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
                                  Text(
                                    previewLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: foregroundColor.withValues(
                                        alpha: .75,
                                      ),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              key: const Key('novel-reader-theme'),
                              tooltip: context.l10n.novel_readerTheme,
                              onPressed: () {
                                onInteraction();
                                onTheme();
                              },
                              icon: Icon(
                                Icons.palette_outlined,
                                color: foregroundColor,
                              ),
                            ),
                            IconButton(
                              key: const Key('novel-reader-settings'),
                              tooltip: context.l10n.reader_settings,
                              onPressed: () {
                                onInteraction();
                                onSettings();
                              },
                              icon: Icon(
                                Icons.text_fields_rounded,
                                color: foregroundColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
