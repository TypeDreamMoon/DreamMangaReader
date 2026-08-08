import 'package:flutter/material.dart';

import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/novel/reader/novel_reader_data.dart';

enum NovelReaderToolsTab { directory, bookmarks, notes }

class NovelReaderToolsSheet extends StatefulWidget {
  const NovelReaderToolsSheet({
    super.key,
    required this.chapters,
    required this.currentChapterId,
    required this.data,
    required this.unresolvedAnnotationIds,
    required this.initialTab,
    required this.onChapterSelected,
    required this.onBookmarkSelected,
    required this.onAnnotationSelected,
    required this.onEditAnnotation,
    required this.onDeleteBookmark,
    required this.onDeleteAnnotation,
  });

  final List<NovelChapter> chapters;
  final String currentChapterId;
  final NovelReaderBookData data;
  final Set<String> unresolvedAnnotationIds;
  final NovelReaderToolsTab initialTab;
  final ValueChanged<NovelChapter> onChapterSelected;
  final ValueChanged<NovelBookmark> onBookmarkSelected;
  final ValueChanged<NovelAnnotation> onAnnotationSelected;
  final ValueChanged<NovelAnnotation> onEditAnnotation;
  final ValueChanged<NovelBookmark> onDeleteBookmark;
  final ValueChanged<NovelAnnotation> onDeleteAnnotation;

  @override
  State<NovelReaderToolsSheet> createState() => _NovelReaderToolsSheetState();
}

class _NovelReaderToolsSheetState extends State<NovelReaderToolsSheet> {
  late NovelReaderToolsTab _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: SegmentedButton<NovelReaderToolsTab>(
              segments: [
                ButtonSegment(
                  value: NovelReaderToolsTab.directory,
                  label: Text(context.l10n.novel_readerToolsDirectory),
                  icon: const Icon(
                    Icons.format_list_bulleted_rounded,
                    key: Key('novel-tools-tab-directory'),
                  ),
                ),
                ButtonSegment(
                  value: NovelReaderToolsTab.bookmarks,
                  label: Text(context.l10n.novel_readerToolsBookmarks),
                  icon: const Icon(
                    Icons.bookmarks_outlined,
                    key: Key('novel-tools-tab-bookmarks'),
                  ),
                ),
                ButtonSegment(
                  value: NovelReaderToolsTab.notes,
                  label: Text(context.l10n.novel_readerToolsNotes),
                  icon: const Icon(
                    Icons.edit_note_rounded,
                    key: Key('novel-tools-tab-notes'),
                  ),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) {
                setState(() => _tab = selection.first);
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() => switch (_tab) {
        NovelReaderToolsTab.directory => _directory(),
        NovelReaderToolsTab.bookmarks => _bookmarks(),
        NovelReaderToolsTab.notes => _notes(),
      };

  Widget _directory() {
    return ListView.builder(
      key: const Key('novel-tools-directory-list'),
      itemCount: widget.chapters.length,
      itemBuilder: (context, index) {
        final chapter = widget.chapters[index];
        return ListTile(
          selected: chapter.id == widget.currentChapterId,
          leading: SizedBox(
            width: 36,
            child: Text('${index + 1}', textAlign: TextAlign.center),
          ),
          title: Text(chapter.title),
          onTap: () => widget.onChapterSelected(chapter),
        );
      },
    );
  }

  Widget _bookmarks() {
    final values = widget.data.bookmarks.values
        .where((value) => !value.isDeleted)
        .toList(growable: false)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (values.isEmpty) {
      return Center(child: Text(context.l10n.novel_readerNoBookmarks));
    }
    return ListView.builder(
      key: const Key('novel-tools-bookmark-list'),
      itemCount: values.length,
      itemBuilder: (context, index) {
        final bookmark = values[index];
        return ListTile(
          leading: const Icon(Icons.bookmark_rounded),
          title: Text(bookmark.excerpt),
          subtitle: Text(_chapterTitle(bookmark.locator.chapterId)),
          onTap: () => widget.onBookmarkSelected(bookmark),
          trailing: IconButton(
            tooltip: context.l10n.novel_readerDeleteBookmark,
            onPressed: () => widget.onDeleteBookmark(bookmark),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        );
      },
    );
  }

  Widget _notes() {
    final values = widget.data.annotations.values
        .where((value) => !value.isDeleted)
        .toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (values.isEmpty) {
      return Center(child: Text(context.l10n.novel_readerNoNotes));
    }
    return ListView.builder(
      key: const Key('novel-tools-note-list'),
      itemCount: values.length,
      itemBuilder: (context, index) {
        final annotation = values[index];
        final unresolved =
            widget.unresolvedAnnotationIds.contains(annotation.id);
        final note = annotation.note;
        return ListTile(
          leading: Icon(
            note == null ? Icons.border_color_rounded : Icons.edit_note_rounded,
          ),
          title: Text(note ?? annotation.range.quote),
          subtitle: Text(
            unresolved
                ? context.l10n.novel_readerRelocatePending
                : _chapterTitle(annotation.range.start.chapterId),
          ),
          onTap: () => widget.onAnnotationSelected(annotation),
          trailing: Wrap(
            spacing: 0,
            children: [
              IconButton(
                tooltip: context.l10n.novel_readerEditNote,
                onPressed: () => widget.onEditAnnotation(annotation),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: context.l10n.delete,
                onPressed: () => widget.onDeleteAnnotation(annotation),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        );
      },
    );
  }

  String _chapterTitle(String chapterId) {
    for (final chapter in widget.chapters) {
      if (chapter.id == chapterId) return chapter.title;
    }
    return chapterId;
  }
}
