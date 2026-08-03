import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/library_store.dart';
import '../../app/novel_download_store.dart';
import '../../app/novel_library_store.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/novel/novel_source.dart';
import '../../core/source/source_registry.dart';
import 'novel_cover.dart';
import 'novel_reader_page.dart';
import 'novel_source_sheet.dart';

class NovelDetailPage extends StatefulWidget {
  const NovelDetailPage({
    super.key,
    required this.meta,
    required this.novel,
    this.sourceBuilder = buildNovelSource,
    this.sourceCatalog,
  });

  final SourceMeta meta;
  final Novel novel;
  final NovelSourceFactory sourceBuilder;
  final List<SourceMeta>? sourceCatalog;

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  late SourceMeta _meta = widget.meta;
  late Novel _novel = widget.novel;
  NovelSource? _source;
  List<NovelChapter> _chapters = const [];
  Object? _error;
  bool _loading = true;
  bool _descriptionExpanded = false;
  int _loadGeneration = 0;

  String get _libraryKey => NovelIdentity.remote(_meta.id, _novel.id).key;

  @override
  void initState() {
    super.initState();
    unawaited(_load(_meta, _novel));
  }

  Future<void> _load(SourceMeta meta, Novel seed) async {
    final generation = ++_loadGeneration;
    final previous = _source;
    _source = null;
    previous?.dispose();
    if (mounted) {
      setState(() {
        _meta = meta;
        _novel = seed;
        _chapters = const [];
        _error = null;
        _loading = true;
        _descriptionExpanded = false;
      });
    }

    NovelSource? source;
    try {
      source = widget.sourceBuilder(meta);
      if (!mounted || generation != _loadGeneration) {
        source.dispose();
        return;
      }
      _source = source;
      final values = await Future.wait<Object>([
        source.getNovelDetail(seed.id),
        _loadAllChapters(source, seed.id),
      ]);
      if (!mounted || generation != _loadGeneration || _source != source) {
        return;
      }
      setState(() {
        _novel = values[0] as Novel;
        _chapters = values[1] as List<NovelChapter>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration || _source != source) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<List<NovelChapter>> _loadAllChapters(
    NovelSource source,
    String novelId,
  ) async {
    final chapters = <NovelChapter>[];
    for (var page = 1; page <= 500; page++) {
      final result = await source.getNovelChapters(novelId, page: page);
      chapters.addAll(result.items);
      if (!result.hasNext || result.items.isEmpty) break;
    }
    return List.unmodifiable(chapters);
  }

  Future<void> _changeSource() async {
    final library = LibraryScope.read(context);
    final catalog = (widget.sourceCatalog ?? registeredSources)
        .where((source) =>
            source.isNovel &&
            (library.isSourceEnabled(source.id) || source.id == _meta.id))
        .toList(growable: false);
    final match = await showNovelSourceSheet(
      context,
      title: _novel.title,
      currentSourceId: _meta.id,
      sources: catalog,
      sourceBuilder: widget.sourceBuilder,
    );
    if (match == null || !mounted) return;
    await _load(match.meta, match.novel);
  }

  void _toggleFavorite() {
    final library = NovelLibraryScope.read(context);
    library.toggleRemoteFavorite(NovelLibraryEntry.remote(
      sourceId: _meta.id,
      novelId: _novel.id,
      title: _novel.title,
      authors: _novel.authors,
      cover: _novel.cover,
    ));
    setState(() {});
  }

  Future<void> _openBrowser() async {
    final uri = Uri.tryParse(_novel.url ?? '');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openChapter(int index) {
    final source = _source;
    if (source == null) return;
    final meta = _meta;
    final novel = _novel;
    final chapters = _chapters;
    final downloads = NovelDownloadScope.read(context);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NovelReaderPage(
        novel: novel,
        chapters: chapters,
        initialIndex: index,
        libraryKey: NovelIdentity.remote(meta.id, novel.id).key,
        loadDocument: (chapter) async {
          final cached = await downloads.localDocument(
            meta.id,
            novel.id,
            chapter.id,
          );
          if (cached != null) {
            return NovelDocument(
              format: NovelDocumentFormat.html,
              content: cached.html,
              baseUrl: Uri.directory(cached.directory).toString(),
            );
          }
          return source.getNovelDocument(novel.id, chapter.id);
        },
      ),
    ));
  }

  void _downloadChapter(NovelChapter chapter) {
    NovelDownloadScope.read(context).enqueue(_meta, _novel, chapter);
  }

  Future<void> _downloadAll() async {
    final downloads = NovelDownloadScope.read(context);
    final pending = _chapters
        .where((chapter) => !downloads.isDownloaded(
              _meta.id,
              _novel.id,
              chapter.id,
            ))
        .toList(growable: false);
    if (pending.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.detail_downloadAll),
        content: Text(context.l10n.detail_downloadNConfirm(pending.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.detail_download),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final chapter in pending) {
      downloads.enqueue(_meta, _novel, chapter);
    }
  }

  @override
  Widget build(BuildContext context) {
    final novelLibrary = NovelLibraryScope.of(context);
    final favorite = novelLibrary.entryFor(_libraryKey)?.favorite == true;
    final activeId = novelLibrary.progressFor(_libraryKey)?.chapterId;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: scheme.onPrimary,
        title: Text(
          _novel.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_novel.url != null)
            IconButton(
              tooltip: context.l10n.novel_openInBrowser,
              onPressed: _openBrowser,
              icon: const Icon(Icons.open_in_new_rounded),
            ),
          IconButton(
            tooltip: favorite
                ? context.l10n.novel_removeFavorite
                : context.l10n.novel_addFavorite,
            onPressed: _toggleFavorite,
            icon: Icon(
              favorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            ),
          ),
          IconButton(
            key: const Key('novel-change-source'),
            tooltip: context.l10n.novel_switchSource,
            onPressed: _loading ? null : _changeSource,
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
        ],
      ),
      body: _error != null
          ? _ErrorView(error: _error!, onRetry: () => _load(_meta, _novel))
          : DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.primary.withValues(alpha: .16),
                    Colors.transparent,
                  ],
                  stops: const [0, .55],
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 760
                    ? _wideBody(context, favorite, activeId)
                    : _narrowBody(context, favorite, activeId),
              ),
            ),
    );
  }

  Widget _narrowBody(
    BuildContext context,
    bool favorite,
    String? activeId,
  ) {
    return Center(
      child: ConstrainedBox(
        key: const Key('novel-detail-narrow'),
        constraints: const BoxConstraints(maxWidth: 820),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _hero(context)),
            SliverToBoxAdapter(child: _actions(context, favorite)),
            SliverToBoxAdapter(child: _description(context)),
            SliverToBoxAdapter(
              child: _directoryPane(
                context,
                activeId,
                height: (MediaQuery.sizeOf(context).height * .72)
                    .clamp(460, 680)
                    .toDouble(),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }

  Widget _wideBody(
    BuildContext context,
    bool favorite,
    String? activeId,
  ) {
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        key: const Key('novel-detail-wide'),
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 380,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  children: [
                    _hero(context),
                    _actions(context, favorite),
                    _description(context),
                  ],
                ),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: scheme.outlineVariant,
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: topInset),
                child: _directoryPane(context, activeId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(BuildContext context) {
    final authors = _novel.authors.where((value) => value.trim().isNotEmpty);
    final genres = _novel.genres.where((value) => value.trim().isNotEmpty);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: const Key('novel-detail-hero'),
      height: 292,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primary, scheme.tertiary],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: .12),
                  Colors.black.withValues(alpha: .72),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 94,
                  child: NovelCover(
                    novel: _novel,
                    headers: imageHeadersOf(_meta),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .34),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Text(
                            _meta.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _novel.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                      if (authors.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          authors.join(' / '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Text(
                            _statusLabel(context, _novel.status),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              letterSpacing: 0,
                            ),
                          ),
                          for (final genre in genres.take(3))
                            Text(
                              genre,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                letterSpacing: 0,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, bool favorite) {
    final progress = NovelLibraryScope.read(context).progressFor(_libraryKey);
    final activeIndex = progress == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == progress.chapterId);
    final startIndex = activeIndex < 0 ? 0 : activeIndex;
    final canRead = !_loading && _chapters.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: canRead ? () => _openChapter(startIndex) : null,
              icon: Icon(
                progress == null
                    ? Icons.play_arrow_rounded
                    : Icons.play_circle_fill_rounded,
              ),
              label: Text(
                context.l10n.novel_continueReading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: favorite
                ? context.l10n.novel_removeFavorite
                : context.l10n.novel_addFavorite,
            onPressed: _toggleFavorite,
            icon: Icon(
              favorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            tooltip: context.l10n.detail_downloadAll,
            onPressed: canRead ? _downloadAll : null,
            icon: const Icon(Icons.download_rounded),
          ),
          if (_novel.url != null) ...[
            const SizedBox(width: 4),
            IconButton.filledTonal(
              tooltip: context.l10n.novel_openInBrowser,
              onPressed: _openBrowser,
              icon: const Icon(Icons.open_in_browser_rounded),
            ),
          ],
        ],
      ),
    );
  }

  Widget _description(BuildContext context) {
    final description = (_novel.description ?? '').trim();
    if (description.isEmpty) return const SizedBox.shrink();
    final canExpand = description.runes.length > 140;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            description,
            key: const Key('novel-detail-description'),
            maxLines: _descriptionExpanded ? null : 10,
            overflow: _descriptionExpanded
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.55,
                  letterSpacing: 0,
                ),
          ),
          if (canExpand)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(
                  () => _descriptionExpanded = !_descriptionExpanded,
                ),
                icon: Icon(
                  _descriptionExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: Text(
                  _descriptionExpanded
                      ? context.l10n.detail_collapse
                      : context.l10n.detail_expandAll,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _directoryPane(
    BuildContext context,
    String? activeId, {
    double? height,
  }) {
    final activeIndex = activeId == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == activeId);
    final content = Column(
      children: [
        Padding(
          key: const Key('novel-detail-directory'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Row(
            children: [
              Text(
                context.l10n.novel_directory,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              Text(
                context.l10n.novel_chaptersN(_chapters.length),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_chapters.isEmpty)
          Expanded(
            child: Center(child: Text(context.l10n.novel_noChapters)),
          )
        else
          Expanded(
            child: ScrollablePositionedList.builder(
              key: ValueKey(
                'novel-directory-${_meta.id}-${_novel.id}-'
                '${_chapters.length}-$activeIndex',
              ),
              initialScrollIndex: activeIndex < 0 ? 0 : activeIndex,
              initialAlignment: activeIndex < 0 ? 0 : .18,
              itemCount: _chapters.length,
              itemBuilder: (context, index) => _chapterRow(
                context,
                index,
                activeId: activeId,
              ),
            ),
          ),
      ],
    );
    if (height == null) return content;
    return SizedBox(height: height, child: content);
  }

  Widget _chapterRow(
    BuildContext context,
    int index, {
    required String? activeId,
  }) {
    final chapter = _chapters[index];
    final previous = index == 0 ? null : _chapters[index - 1];
    final showVolume = chapter.volumeId != null &&
        (previous == null || previous.volumeId != chapter.volumeId);
    final downloads = NovelDownloadScope.read(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showVolume)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
            child: Text(
              chapter.volumeTitle ?? '',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ListTile(
          key:
              chapter.id == activeId ? const Key('novel-chapter-active') : null,
          selected: chapter.id == activeId,
          leading: SizedBox(
            width: 42,
            child: Text('${index + 1}', textAlign: TextAlign.center),
          ),
          title: Text(
            chapter.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _openChapter(index),
          trailing: AnimatedBuilder(
            animation: downloads,
            builder: (context, _) {
              if (downloads.isDownloaded(_meta.id, _novel.id, chapter.id)) {
                return const Icon(Icons.offline_pin_rounded);
              }
              final progress =
                  downloads.progressOf(_meta.id, _novel.id, chapter.id);
              if (progress != null) {
                return SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(value: progress),
                );
              }
              final failure =
                  downloads.failureOf(_meta.id, _novel.id, chapter.id);
              return IconButton(
                tooltip: failure == null
                    ? context.l10n.novel_downloadChapter
                    : context.l10n.novel_retryDownload,
                onPressed: failure == null
                    ? () => _downloadChapter(chapter)
                    : () => downloads.retry(_meta.id, _novel.id, chapter.id),
                icon: Icon(failure == null
                    ? Icons.download_rounded
                    : Icons.refresh_rounded),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _source?.dispose();
    super.dispose();
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 42),
            const SizedBox(height: 12),
            Text(
              context.l10n.novel_loadFailed('$error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(BuildContext context, NovelStatus status) =>
    switch (status) {
      NovelStatus.ongoing => context.l10n.novel_statusOngoing,
      NovelStatus.completed => context.l10n.novel_statusCompleted,
      NovelStatus.hiatus => context.l10n.novel_statusHiatus,
      NovelStatus.cancelled => context.l10n.novel_statusCancelled,
      NovelStatus.unknown => context.l10n.novel_statusUnknown,
    };
