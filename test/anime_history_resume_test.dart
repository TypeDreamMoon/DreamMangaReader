import 'dart:async';

import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/anime/anime_history_resume.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('episode id wins over a stale saved index', (tester) async {
    late int openedIndex;
    late Duration openedPosition;
    final source = _ResumeSource();
    await tester.pumpWidget(_app(Builder(builder: (context) {
      return TextButton(
        onPressed: () => unawaited(openAnimeHistory(
          context,
          _history(episodeId: 'ep-2', episodeIndex: 0),
          sources: const [_meta],
          sourceBuilder: (_) => source,
          playerBuilder: (meta, animeId, title, episodes, index, position) {
            openedIndex = index;
            openedPosition = position;
            return const Scaffold(body: Text('播放器占位'));
          },
        )),
        child: const Text('恢复'),
      );
    })));

    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(openedIndex, 1);
    expect(openedPosition, const Duration(seconds: 83));
    expect(source.disposed, isTrue);
    expect(find.text('播放器占位'), findsOneWidget);
  });

  testWidgets('missing episode id falls back to a clamped index',
      (tester) async {
    late int openedIndex;
    await tester.pumpWidget(_app(Builder(builder: (context) {
      return TextButton(
        onPressed: () => unawaited(openAnimeHistory(
          context,
          _history(episodeId: 'removed', episodeIndex: 99),
          sources: const [_meta],
          sourceBuilder: (_) => _ResumeSource(),
          playerBuilder: (meta, animeId, title, episodes, index, position) {
            openedIndex = index;
            return const Scaffold(body: Text('播放器占位'));
          },
        )),
        child: const Text('恢复'),
      );
    })));

    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(openedIndex, 1);
  });

  testWidgets('resolution failure reports an error without mutating history',
      (tester) async {
    final entry = _history(episodeId: 'ep-1', episodeIndex: 0);
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => unawaited(openAnimeHistory(
            context,
            entry,
            sources: const [_meta],
            sourceBuilder: (_) => _ResumeSource(fail: true),
          )),
          child: const Text('恢复'),
        );
      }),
    )));

    await tester.tap(find.text('恢复'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('恢复播放失败'), findsOneWidget);
    expect(entry.episodeId, 'ep-1');
    expect(entry.positionSeconds, 83);
  });
}

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    );

const _meta = SourceMeta(
  id: 'anime-source',
  name: '测试源',
  script: '',
  kind: 'anime',
);

AnimeHistoryEntry _history({
  required String episodeId,
  required int episodeIndex,
}) =>
    AnimeHistoryEntry(
      sourceId: _meta.id,
      animeId: 'show',
      title: '测试番剧',
      episodeId: episodeId,
      episodeName: '旧分集名',
      episodeIndex: episodeIndex,
      positionSeconds: 83,
      durationSeconds: 1440,
      updatedAt: 10,
    );

class _ResumeSource implements MangaSource {
  _ResumeSource({this.fail = false});

  final bool fail;
  bool disposed = false;

  @override
  String get id => _meta.id;
  @override
  String get name => _meta.name;
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => '';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async {
    if (fail) throw StateError('fixture failure');
    return const Paged([
      Chapter(id: 'ep-1', name: '第一集'),
      Chapter(id: 'ep-2', name: '第二集'),
    ]);
  }

  @override
  void dispose() => disposed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
