import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/library_store.dart';
import '../../app/source_controller.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/novel/novel_source.dart';
import '../../core/source/chinese_fold.dart';
import '../../core/source/models.dart';
import '../../core/source/search_rank.dart';
import '../../core/source/source_registry.dart';
import '../../core/translate/translated_search.dart';
import '../common/source_picker.dart';
import '../common/transitions.dart';
import 'novel_cover.dart';
import 'novel_detail_page.dart';
import 'novel_source_sheet.dart';

class NovelBrowser extends StatefulWidget {
  const NovelBrowser({
    super.key,
    this.sourceBuilder = buildNovelSource,
    this.sourceCatalog,
  });

  final NovelSourceFactory sourceBuilder;
  final List<SourceMeta>? sourceCatalog;

  @override
  State<NovelBrowser> createState() => NovelBrowserState();
}

class _NovelResult {
  _NovelResult({required this.novel, required this.meta});

  final Novel novel;
  final SourceMeta meta;
  final Set<String> sourceIds = {};
}

class _NovelCursor {
  _NovelCursor(this.meta, this.source);

  final SourceMeta meta;
  final NovelSource source;
  int page = 1;
  bool hasNext = true;
  bool loading = false;
  bool failed = false;
}

class NovelBrowserState extends State<NovelBrowser> {
  static const _mixedId = '__novel_all__';

  final ScrollController _scroll = ScrollController();
  final List<_NovelResult> _results = [];
  final Map<String, _NovelResult> _byTitle = {};
  final List<_NovelCursor> _mixedSources = [];
  final Map<String, String> _selectedFilters = {};
  final Set<String> _failedSources = {};
  final Set<String> _buildFailedSources = {};

  SourceController? _sourceController;
  SourceMeta? _meta;
  NovelSource? _source;
  List<FilterDef> _filters = const [];
  int _page = 1;
  int _loadGeneration = 0;
  bool _initialized = false;
  bool _mixed = true;
  bool _loading = false;
  bool _hasNext = true;
  Object? _error;
  Object? _sourceBuildError;
  String _query = '';
  String _originalQuery = '';
  List<String>? _fallbackQueue;

  void runSearch(String query) {
    _query = query.trim();
    _originalQuery = _query;
    _fallbackQueue = null;
    _reset();
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = SourceScope.of(context);
    final changed = controller != _sourceController;
    if (changed) {
      _sourceController?.removeListener(_onSelectedSourceChanged);
      _sourceController = controller..addListener(_onSelectedSourceChanged);
    }
    final shouldMix = !LibraryScope.of(context).showSourcePicker;
    if (!_initialized || changed || shouldMix != _mixed) {
      _initialized = true;
      _mixed = shouldMix;
      _configureSources();
    }
  }

  List<SourceMeta> get _enabledSources {
    final library = LibraryScope.read(context);
    return [
      for (final source in widget.sourceCatalog ?? registeredSources)
        if (source.isNovel && library.isSourceEnabled(source.id)) source,
    ];
  }

  void _onSelectedSourceChanged() {
    if (!_mixed) _configureSources();
  }

  void _disposeSources() {
    _source?.dispose();
    _source = null;
    for (final cursor in _mixedSources) {
      cursor.source.dispose();
    }
    _mixedSources.clear();
  }

  void _configureSources() {
    _disposeSources();
    _filters = const [];
    _selectedFilters.clear();
    _buildFailedSources.clear();
    _sourceBuildError = null;
    final sources = _enabledSources;
    if (_mixed) {
      _meta = null;
      for (final meta in sources) {
        try {
          _mixedSources.add(_NovelCursor(meta, widget.sourceBuilder(meta)));
        } catch (_) {
          _buildFailedSources.add(meta.id);
        }
      }
    } else {
      final selected = _sourceController?.currentFor('novel');
      _meta = sources.where((item) => item.id == selected?.id).firstOrNull ??
          sources.firstOrNull;
      final meta = _meta;
      if (meta != null) {
        try {
          _source = widget.sourceBuilder(meta);
          _filters = _source!.filters;
          for (final filter in _filters) {
            if (filter.options.isNotEmpty) {
              _selectedFilters[filter.id] = filter.options.first.value;
            }
          }
        } catch (error) {
          _sourceBuildError = error;
        }
      }
    }
    _reset();
  }

  void _reset() {
    _loadGeneration++;
    for (final cursor in _mixedSources) {
      cursor
        ..page = 1
        ..hasNext = true
        ..loading = false
        ..failed = false;
    }
    if (mounted) {
      setState(() {
        _results.clear();
        _byTitle.clear();
        _failedSources
          ..clear()
          ..addAll(_buildFailedSources);
        _page = 1;
        _loading = false;
        _hasNext = true;
        _error = _sourceBuildError;
      });
    }
    unawaited(_loadMore());
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 500) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasNext) return;
    if (_mixed && _mixedSources.isEmpty) return;
    if (!_mixed && _source == null) return;
    final generation = _loadGeneration;
    setState(() => _loading = true);
    if (_mixed) {
      final cursors = _mixedSources
          .where((cursor) => cursor.hasNext && !cursor.loading)
          .toList(growable: false);
      await Future.wait([
        for (final cursor in cursors) _loadMixedCursor(cursor, generation),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _hasNext = _mixedSources.any((cursor) => cursor.hasNext);
        if (_results.isEmpty &&
            _failedSources.length == _enabledSources.length) {
          _error = StateError(context.l10n.novel_browserAllSourcesFailed);
        }
      });
    } else {
      try {
        final result = _query.isEmpty
            ? await _source!.getNovelDiscovery(
                _page,
                filters: _activeFilters,
              )
            : await _source!.getNovelSearch(
                _query,
                _page,
                filters: _activeFilters,
              );
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          for (final novel in result.items) {
            _addResult(novel, _meta!);
          }
          _page++;
          _hasNext = result.hasNext && result.items.isNotEmpty;
          _loading = false;
          _error = null;
          _sortResults();
        });
      } catch (error) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
    await _maybeUseTranslatedQuery(generation);
  }

  Future<void> _loadMixedCursor(
    _NovelCursor cursor,
    int generation,
  ) async {
    cursor.loading = true;
    try {
      final result = _query.isEmpty
          ? await cursor.source.getNovelDiscovery(cursor.page)
          : await cursor.source.getNovelSearch(_query, cursor.page);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        for (final novel in result.items) {
          _addResult(novel, cursor.meta);
        }
        cursor.page++;
        cursor.hasNext = result.hasNext && result.items.isNotEmpty;
        cursor.failed = false;
        _failedSources.remove(cursor.meta.id);
        _sortResults();
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        cursor.failed = true;
        cursor.hasNext = false;
        _failedSources.add(cursor.meta.id);
      });
    } finally {
      cursor.loading = false;
    }
  }

  void _addResult(Novel novel, SourceMeta meta) {
    final key = ChineseFold.dedupKey(novel.title);
    if (key.isEmpty) return;
    final current = _byTitle[key];
    if (current != null) {
      current.sourceIds.add(meta.id);
      return;
    }
    final result = _NovelResult(novel: novel, meta: meta)
      ..sourceIds.add(meta.id);
    _byTitle[key] = result;
    _results.add(result);
  }

  void _sortResults() {
    if (_originalQuery.isEmpty) return;
    _results.sort((a, b) => searchRelevance(
          b.novel.title,
          _originalQuery,
        ).compareTo(searchRelevance(a.novel.title, _originalQuery)));
  }

  Future<void> _maybeUseTranslatedQuery(int generation) async {
    if (!mounted ||
        generation != _loadGeneration ||
        _loading ||
        _query.isEmpty ||
        _results.isNotEmpty ||
        _error != null ||
        !LibraryScope.read(context).translateSearch) {
      return;
    }
    if (_fallbackQueue == null) {
      _fallbackQueue = const [];
      final library = LibraryScope.read(context);
      final variants = await TranslatedSearch.variants(
        _originalQuery,
        providers: library.translateProviderOrder,
        targets: library.translateTargetsFor(_originalQuery),
        llm: library.translateLlm,
      );
      if (!mounted || generation != _loadGeneration) return;
      _fallbackQueue = List.of(variants);
    }
    if (_fallbackQueue!.isNotEmpty) {
      _query = _fallbackQueue!.removeAt(0);
      _reset();
    }
  }

  Map<String, Object?> get _activeFilters => {
        for (final entry in _selectedFilters.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value,
      };

  Future<void> _pickSource() async {
    final selected = await showSourcePicker(
      context,
      currentId: _mixed ? _mixedId : (_meta?.id ?? ''),
      includeMixed: true,
      mixedId: _mixedId,
      kind: 'novel',
    );
    if (selected == null || !mounted) return;
    if (selected == _mixedId) {
      if (_mixed) return;
      _mixed = true;
      _configureSources();
      return;
    }
    final meta =
        _enabledSources.where((item) => item.id == selected).firstOrNull;
    if (meta == null) return;
    _mixed = false;
    final controller = _sourceController;
    if (controller?.currentFor('novel')?.id == meta.id) {
      _configureSources();
    } else {
      controller?.selectFor('novel', meta);
    }
  }

  void _open(_NovelResult result) {
    Navigator.of(context).push(appRoute(NovelDetailPage(
      meta: result.meta,
      novel: result.novel,
      sourceBuilder: widget.sourceBuilder,
      sourceCatalog: widget.sourceCatalog,
    )));
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_enabledSources.isEmpty) {
      return Center(child: Text(context.l10n.novel_browserNoSources));
    }
    return Column(
      children: [
        if (library.showSourcePicker)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SourcePickerPill(
                label: _mixed
                    ? context.l10n.novel_browserAllSources
                    : (_meta?.name ?? context.l10n.novel_browserSource),
                icon: Icons.auto_stories_rounded,
                onTap: _pickSource,
              ),
            ),
          ),
        if (!_mixed && _filters.isNotEmpty && _query.isEmpty)
          _filterBar(scheme),
        if (_query.isNotEmpty &&
            _query != _originalQuery &&
            _results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              context.l10n.novel_browserTranslatedQuery(
                _originalQuery,
                _query,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_failedSources.isNotEmpty && _results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    context.l10n.novel_browserPartialFailure(
                      _failedSources.length,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        Expanded(child: _content(scheme)),
      ],
    );
  }

  Widget _filterBar(ColorScheme scheme) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final filter in _filters)
            for (final option in filter.options)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(option.label),
                  selected: _selectedFilters[filter.id] == option.value,
                  onSelected: (_) {
                    _selectedFilters[filter.id] = option.value;
                    _reset();
                  },
                ),
              ),
        ],
      ),
    );
  }

  Widget _content(ColorScheme scheme) {
    if (_results.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 42, color: scheme.error),
              const SizedBox(height: 12),
              Text(
                context.l10n.novel_browserLoadFailed('$_error'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.l10n.retry),
              ),
            ],
          ),
        );
      }
      return Center(child: Text(context.l10n.novel_browserNoResults));
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 176,
        crossAxisSpacing: 12,
        mainAxisSpacing: 14,
        childAspectRatio: .58,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _open(result),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NovelCover(
                      novel: result.novel,
                      headers: imageHeadersOf(result.meta),
                      compactGeneratedTitle: true,
                    ),
                    if (result.sourceIds.length > 1)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            child: Text(
                              context.l10n.novel_browserSourceCount(
                                result.sourceIds.length,
                              ),
                              style: TextStyle(
                                color: scheme.onPrimary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                result.novel.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              Text(
                result.meta.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _sourceController?.removeListener(_onSelectedSourceChanged);
    _disposeSources();
    _scroll.dispose();
    super.dispose();
  }
}
