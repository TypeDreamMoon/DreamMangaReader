import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/library_store.dart';
import '../../app/novel_download_store.dart';
import '../../app/novel_library_store.dart';
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

  @override
  Widget build(BuildContext context) {
    final favorite =
        NovelLibraryScope.read(context).entryFor(_libraryKey)?.favorite == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _novel.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_novel.url != null)
            IconButton(
              tooltip: '在浏览器打开',
              onPressed: _openBrowser,
              icon: const Icon(Icons.open_in_new_rounded),
            ),
          IconButton(
            tooltip: favorite ? '取消收藏' : '收藏',
            onPressed: _toggleFavorite,
            icon: Icon(
              favorite ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            ),
          ),
          IconButton(
            key: const Key('novel-change-source'),
            tooltip: '切换来源',
            onPressed: _loading ? null : _changeSource,
            icon: const Icon(Icons.swap_horiz_rounded),
          ),
        ],
      ),
      body: _error != null
          ? _ErrorView(error: _error!, onRetry: () => _load(_meta, _novel))
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                  sliver: SliverToBoxAdapter(child: _header(context)),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Row(
                      children: [
                        Text('目录',
                            style: Theme.of(context).textTheme.titleMedium),
                        const Spacer(),
                        Text('${_chapters.length} 章',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
                if (_loading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_chapters.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('暂无章节')),
                  )
                else
                  SliverList.builder(
                    itemCount: _chapters.length,
                    itemBuilder: (context, index) =>
                        _chapterRow(context, index),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 28)),
              ],
            ),
    );
  }

  Widget _header(BuildContext context) {
    final authors = _novel.authors.where((value) => value.trim().isNotEmpty);
    final genres = _novel.genres.where((value) => value.trim().isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              child: NovelCover(
                novel: _novel,
                headers: imageHeadersOf(_meta),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _novel.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(_meta.name,
                      style: Theme.of(context).textTheme.labelLarge),
                  if (authors.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(authors.join(' / '),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 6),
                  Text(_statusLabel(_novel.status)),
                  if (genres.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final genre in genres.take(5))
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(genre),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if ((_novel.description ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            _novel.description!.trim(),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ],
    );
  }

  Widget _chapterRow(BuildContext context, int index) {
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
                tooltip: failure == null ? '下载本章' : '重试下载',
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
            Text('加载失败\n$error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(NovelStatus status) => switch (status) {
      NovelStatus.ongoing => '连载中',
      NovelStatus.completed => '已完结',
      NovelStatus.hiatus => '暂停更新',
      NovelStatus.cancelled => '已取消',
      NovelStatus.unknown => '状态未知',
    };
