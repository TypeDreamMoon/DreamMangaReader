import 'package:flutter/material.dart';

import '../../core/novel/models.dart';
import '../../core/novel/novel_source.dart';
import '../../core/source/source_registry.dart';

typedef NovelSourceFactory = NovelSource Function(SourceMeta meta);

class NovelSourceMatch {
  const NovelSourceMatch({required this.meta, required this.novel});

  final SourceMeta meta;
  final Novel novel;
}

Future<NovelSourceMatch?> showNovelSourceSheet(
  BuildContext context, {
  required String title,
  required String currentSourceId,
  required List<SourceMeta> sources,
  required NovelSourceFactory sourceBuilder,
}) {
  return showModalBottomSheet<NovelSourceMatch>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _NovelSourceSheet(
      title: title,
      currentSourceId: currentSourceId,
      sources: sources,
      sourceBuilder: sourceBuilder,
    ),
  );
}

class _NovelSourceSheet extends StatefulWidget {
  const _NovelSourceSheet({
    required this.title,
    required this.currentSourceId,
    required this.sources,
    required this.sourceBuilder,
  });

  final String title;
  final String currentSourceId;
  final List<SourceMeta> sources;
  final NovelSourceFactory sourceBuilder;

  @override
  State<_NovelSourceSheet> createState() => _NovelSourceSheetState();
}

class _NovelSourceSheetState extends State<_NovelSourceSheet> {
  late final Future<List<NovelSourceMatch>> _matches = _search();

  Future<List<NovelSourceMatch>> _search() async {
    final normalized = _normalizeTitle(widget.title);
    if (normalized.isEmpty) return const [];
    final futures = widget.sources
        .where((meta) => meta.isNovel && meta.id != widget.currentSourceId)
        .map((meta) async {
      NovelSource? source;
      try {
        source = widget.sourceBuilder(meta);
        final result = await source.getNovelSearch(widget.title, 1);
        Novel? fallback;
        for (final novel in result.items) {
          final candidate = _normalizeTitle(novel.title);
          if (candidate == normalized) {
            return NovelSourceMatch(meta: meta, novel: novel);
          }
          if (fallback == null &&
              (candidate.contains(normalized) ||
                  normalized.contains(candidate))) {
            fallback = novel;
          }
        }
        return fallback == null
            ? null
            : NovelSourceMatch(meta: meta, novel: fallback);
      } catch (_) {
        return null;
      } finally {
        source?.dispose();
      }
    });
    final values = await Future.wait(futures);
    return values.whereType<NovelSourceMatch>().toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                '切换小说来源',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: FutureBuilder<List<NovelSourceMatch>>(
                future: _matches,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  final matches = snapshot.data ?? const [];
                  if (matches.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('其他已启用小说源中没有找到同名作品',
                          textAlign: TextAlign.center),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: matches.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final match = matches[index];
                      return ListTile(
                        leading: const Icon(Icons.swap_horiz_rounded),
                        title: Text(match.meta.name),
                        subtitle: Text(
                          match.novel.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.pop(context, match),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _normalizeTitle(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
