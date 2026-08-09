import 'dart:io';

import 'package:dream_manga_reader/app/anime_download_store.dart';
import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/download_coordinator_scope.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/core/downloads/download_coordinator.dart';
import 'package:dream_manga_reader/core/downloads/download_policy.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
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

void main() {
  testWidgets('anime detail favorite action toggles its independent store',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final library = LibraryStore();
    await library.load();
    addTearDown(library.dispose);
    final animeLibrary = AnimeLibraryStore(persistDelay: Duration.zero);
    await animeLibrary.load();
    addTearDown(animeLibrary.dispose);
    // 详情页整页渲染需要下载作用域(收藏键旁边就是「下载全部」)。
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('anime-favorite-test-'),
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

    const meta = SourceMeta(
      id: 'anime-source',
      name: '测试源',
      script: '',
      kind: 'anime',
    );
    // 收藏要落的是**详情补全后**的标题/封面,而不是列表卡带来的残缺信息。
    const seed = Manga(id: 'show', title: '列表标题');

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: LibraryScope(
        store: library,
        child: AnimeLibraryScope(
          store: animeLibrary,
          child: DownloadCoordinatorScope(
            coordinator: coordinator,
            child: AnimeDownloadScope(
              store: downloads,
              child: AnimeDetailPage(
                meta: meta,
                anime: seed,
                sourceBuilder: (_) => _FakeAnimeSource(),
                bangumiLookup: (_) async => null,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('anime-favorite')));
    await tester.pump();

    expect(animeLibrary.isFavorite('anime-source', 'show'), isTrue);
    expect(animeLibrary.favorites.single.title, '完整番剧标题');
    expect(animeLibrary.favorites.single.cover, 'https://img.test/full.jpg');
    await animeLibrary.flushPending();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _FakeAnimeSource implements MangaSource {
  @override
  String get id => 'anime-source';
  @override
  String get name => '测试源';
  @override
  String get lang => 'zh';
  @override
  String get baseUrl => '';
  @override
  int get version => 1;
  @override
  bool get nsfw => false;
  @override
  Future<Manga> getMangaDetail(String mangaId) async => const Manga(
        id: 'show',
        title: '完整番剧标题',
        cover: 'https://img.test/full.jpg',
      );
  @override
  Future<Paged<Chapter>> getChapters(String mangaId, {int? page}) async =>
      const Paged([Chapter(id: 'episode-1', name: '第一集')]);
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
