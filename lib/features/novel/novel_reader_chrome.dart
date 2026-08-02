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

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final surface = scheme.surface.withValues(alpha: .96);
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
              child: Material(
                color: surface,
                child: SafeArea(
                  bottom: false,
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
                              icon: const Icon(Icons.arrow_back_rounded),
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
                                    style:
                                        Theme.of(context).textTheme.titleSmall,
                                  ),
                                  Text(
                                    chapterTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
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
        Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Material(
                key: const Key('novel-reader-bottom-bar'),
                color: surface,
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 78,
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
                              icon: const Icon(
                                Icons.format_list_bulleted_rounded,
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Slider(
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
                                  Text(
                                    previewLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
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
                              icon: const Icon(Icons.palette_outlined),
                            ),
                            IconButton(
                              key: const Key('novel-reader-settings'),
                              tooltip: context.l10n.reader_settings,
                              onPressed: () {
                                onInteraction();
                                onSettings();
                              },
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
          ),
        ),
      ],
    );
  }
}
