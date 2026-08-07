import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/novel/models.dart';
import '../../core/novel/reader/novel_search_index.dart';

enum NovelSearchScope { cached, fullBook }

class NovelReaderSearchSheet extends StatefulWidget {
  const NovelReaderSearchSheet({
    super.key,
    required this.index,
    required this.bookKey,
    required this.sourceFingerprint,
    required this.chapters,
    required this.loadCachedDocument,
    required this.onResultSelected,
    this.fetchDocument,
    this.initialQuery,
  });

  final NovelSearchIndex index;
  final String bookKey;
  final String sourceFingerprint;
  final List<NovelChapter> chapters;
  final NovelSearchDocumentLoader loadCachedDocument;
  final NovelSearchDocumentFetcher? fetchDocument;
  final ValueChanged<NovelSearchResult> onResultSelected;
  final String? initialQuery;

  @override
  State<NovelReaderSearchSheet> createState() => _NovelReaderSearchSheetState();
}

class _NovelReaderSearchSheetState extends State<NovelReaderSearchSheet> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  NovelSearchScope _scope = NovelSearchScope.cached;
  NovelSearchCancellationToken? _cancellation;
  final List<NovelSearchResult> _results = [];
  NovelSearchProgress? _progress;
  String? _status;
  bool _searching = false;
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _cancellation?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _startSearch() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    _cancellation?.cancel();
    final generation = ++_generation;
    final cancellation = NovelSearchCancellationToken();
    _cancellation = cancellation;
    setState(() {
      _results.clear();
      _progress = null;
      _status = null;
      _searching = true;
    });
    try {
      await for (final event in widget.index.search(
        bookKey: widget.bookKey,
        sourceFingerprint: widget.sourceFingerprint,
        chapters: widget.chapters,
        query: query,
        loadCachedDocument: widget.loadCachedDocument,
        fetchMissing: _scope == NovelSearchScope.fullBook,
        fetchDocument: widget.fetchDocument,
        cancellation: cancellation,
      )) {
        if (!mounted || generation != _generation) return;
        setState(() {
          switch (event) {
            case NovelSearchProgress():
              _progress = event;
            case NovelSearchResultBatch():
              _results.addAll(event.results);
            case NovelSearchCompleted():
              _searching = false;
              _status = event.resultCount == 0 ? '没有找到结果' : null;
            case NovelSearchCancelled():
              _searching = false;
              _status = '已取消';
          }
        });
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _searching = false;
        _status = '搜索失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('novel-search-query'),
                        controller: _query,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                          hintText: '搜索书内文字',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                        onSubmitted: (_) => unawaited(_startSearch()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const Key('novel-search-submit'),
                      tooltip: '搜索',
                      onPressed:
                          _searching ? null : () => unawaited(_startSearch()),
                      icon: const Icon(Icons.search_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<NovelSearchScope>(
                        segments: const [
                          ButtonSegment(
                            value: NovelSearchScope.cached,
                            label: Text('已缓存'),
                            icon: Icon(
                              Icons.offline_pin_outlined,
                              key: Key('novel-search-scope-cached'),
                            ),
                          ),
                          ButtonSegment(
                            value: NovelSearchScope.fullBook,
                            label: Text('全书'),
                            icon: Icon(
                              Icons.cloud_download_outlined,
                              key: Key('novel-search-scope-full'),
                            ),
                          ),
                        ],
                        selected: {_scope},
                        onSelectionChanged: _searching
                            ? null
                            : (selection) {
                                setState(() => _scope = selection.first);
                              },
                      ),
                    ),
                    if (_searching) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        key: const Key('novel-search-cancel'),
                        tooltip: '取消搜索',
                        onPressed: _cancellation?.cancel,
                        icon: const Icon(Icons.stop_circle_outlined),
                      ),
                    ],
                  ],
                ),
                if (_searching || _progress != null) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    key: const Key('novel-search-progress'),
                    value: _progress?.fraction,
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _resultBody()),
        ],
      ),
    );
  }

  Widget _resultBody() {
    if (_results.isEmpty) {
      return Center(child: Text(_status ?? ''));
    }
    return ListView.separated(
      key: const Key('novel-search-results'),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final result = _results[index];
        return ListTile(
          title: Text(result.chapterTitle),
          subtitle: Text(result.snippet, maxLines: 3),
          onTap: () => widget.onResultSelected(result),
        );
      },
    );
  }
}
