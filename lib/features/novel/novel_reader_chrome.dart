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

  /// 顶/底栏用**固定深色渐变 + 白字**,和漫画阅读器一套 —— 不走 palette 是有意的:
  /// 阅读画布的底色由读者自己在阅读器里选(纸白 / 米黄 / 夜间…),跟 App 主题无关。
  /// 跟着 App 主题走会出现「浅色主题 + 纸白页面 = 白栏压白纸」这种看不清的组合。
  static const _scrimTop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.black87, Colors.transparent],
  );
  static const _scrimBottom = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Colors.black87, Colors.transparent],
  );

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
                decoration: const BoxDecoration(gradient: _scrimTop),
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
                                icon: const Icon(Icons.arrow_back_rounded,
                                    color: Colors.white),
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      bookTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      chapterTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white60,
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
                decoration: const BoxDecoration(gradient: _scrimBottom),
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
                              icon: const Icon(
                                Icons.format_list_bulleted_rounded,
                                color: Colors.white,
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
                                    style: const TextStyle(
                                      color: Colors.white70,
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
                              icon: const Icon(Icons.palette_outlined,
                                  color: Colors.white),
                            ),
                            IconButton(
                              key: const Key('novel-reader-settings'),
                              tooltip: context.l10n.reader_settings,
                              onPressed: () {
                                onInteraction();
                                onSettings();
                              },
                              icon: const Icon(Icons.text_fields_rounded,
                                  color: Colors.white),
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
