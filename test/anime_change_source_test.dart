import 'dart:io';

import 'package:dream_manga_reader/app/anime_download_store.dart';
import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/download_coordinator_scope.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/features/anime/anime_detail_page.dart';
import 'package:dream_manga_reader/features/anime/playback/hls_cache_gateway.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/download_fixtures.dart';

const _sourceA = SourceMeta(
  id: 'anime-a',
  name: '来源 A',
  script: '',
  kind: 'anime',
);
const _sourceB = SourceMeta(
  id: 'anime-b',
  name: '来源 B',
  script: '',
  kind: 'anime',
);

void main() {
  testWidgets('anime detail can switch to another source', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    // 换源弹层从全局源表里挑候选,测试期间注册两个番剧源。
    final saved = registeredSources;
    registeredSources = [_sourceA, _sourceB];
    addTearDown(() => registeredSources = saved);

    final library = LibraryStore();
    await library.load();
    addTearDown(library.dispose);
    final animeLibrary = AnimeLibraryStore(persistDelay: Duration.zero);
    await animeLibrary.load();
    addTearDown(animeLibrary.dispose);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('anime-change-source-'),
    ))!;
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final downloads = AnimeDownloadStore(
      rootProvider: () async => root.path,
      trackProvider: (_, __, ___) async => const [],
      upstream: _UnusedUpstream(),
    );
    await tester.runAsync(downloads.load);
    addTearDown(downloads.dispose);
    final coordinator = DownloadCoordinator(
      repository: RecordingDownloadTaskRepository(),
      environment: () async => unrestrictedEnvironment,
      settings: DownloadPolicySettings.new,
    );
    await coordinator.load();
    addTearDown(coordinator.dispose);

    // 各作用域放在 MaterialApp **之上** —— 换源走 pushReplacement,新路由挂在
    // Navigator 上,scope 若在 home: 里面新页面就够不着(真机上它们在根部)。
    await tester.pumpWidget(LibraryScope(
      store: library,
      child: AnimeLibraryScope(
        store: animeLibrary,
        child: DownloadCoordinatorScope(
          coordinator: coordinator,
          child: AnimeDownloadScope(
            store: downloads,
            child: MaterialApp(
              theme: buildTheme(AppThemeVariant.light),
              locale: const Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: AnimeDetailPage(
                meta: _sourceA,
                anime: const Manga(id: 'show-a', title: '测试番剧'),
                sourceBuilder: (meta) => _FakeAnimeSource(meta),
                bangumiLookup: (_) async => null,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('A 第一集'), findsWidgets);

    await tester.tap(find.byKey(const Key('anime-change-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('来源 B'));
    await tester.pumpAndSettle();

    // 整页换到了来源 B:分集表来自 B。
    expect(find.text('B 第一集'), findsWidgets);
    expect(find.text('A 第一集'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _FakeAnimeSource implements MangaSource {
  _FakeAnimeSource(this.meta);

  final SourceMeta meta;
  String get _tag => meta.id == 'anime-b' ? 'B' : 'A';

  @override
  String get id => meta.id;
  @override
  String get name => meta.name;
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => '';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  Future<Manga> getMangaDetail(String mangaId) async =>
      Manga(id: mangaId, title: '测试番剧');
  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async =>
      Paged([Chapter(id: '$_tag-1', name: '$_tag 第一集')]);
  @override
  Future<Paged<Manga>> getSearch(String query, int page,
          {Map<String, Object?>? filters}) async =>
      Paged([Manga(id: 'show-$_tag', title: '测试番剧')]);
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _UnusedUpstream implements HlsUpstreamClient {
  @override
  Future<HlsUpstreamResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    int? rangeStart,
    int? rangeLength,
  }) =>
      throw StateError('network not expected');
}
