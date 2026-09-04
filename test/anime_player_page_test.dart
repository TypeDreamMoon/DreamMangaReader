import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'dart:async';
import 'dart:convert';

import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/features/anime/anime_player_page.dart';
import 'package:dream_manga_reader/features/anime/anime_player_controls.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_session_controller.dart';
import 'package:dream_manga_reader/features/anime/playback/playback_state.dart';
import 'package:dream_manga_reader/features/anime/playback/player_adapter.dart';
import 'package:dream_manga_reader/features/anime/playback/subtitle_option.dart';
import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = VideoTrack(
  url: 'https://media.example.test/video.mp4',
  quality: '480p',
);
const _track360 = VideoTrack(
  url: 'https://media.example.test/video-360.mp4',
  quality: '360p',
);
const _subtitled = VideoTrack(
  url: 'https://media.example.test/video.mp4',
  quality: '480p',
  subtitles: [
    SubtitleAsset(url: 'https://media.example.test/zh.vtt', label: '简体中文'),
  ],
);

Widget _host(PlaybackState state, {VoidCallback? onRetry}) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: AnimePlaybackSurface(
          state: state,
          video: const ColoredBox(
            key: ValueKey('video-surface'),
            color: Colors.black,
          ),
          onRetry: onRetry ?? () {},
        ),
      ),
    );

void main() {
  testWidgets('page resumes and stores current episode to the second',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final library = AnimeLibraryStore(persistDelay: Duration.zero);
    await library.load();
    addTearDown(library.dispose);
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimeLibraryScope(
        store: library,
        child: AnimePlayerPage(
          meta: const SourceMeta(
            id: 'test-anime',
            name: 'Test Anime',
            script: '',
            kind: 'anime',
          ),
          animeId: 'anime-1',
          animeTitle: '测试番剧',
          episodes: const [Chapter(id: 'ep-1', name: '第一集')],
          index: 0,
          initialPosition: const Duration(seconds: 83),
          dependencies: dependencies,
        ),
      ),
    ));
    await tester.pump();

    // 断点是**开机位置**,不是打开之后再补的一发 seek —— 后者会在文件就绪前被丢掉。
    expect(adapter.openStarts, [const Duration(seconds: 83)]);
    expect(adapter.seeks, isEmpty);
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.positionController.add(const Duration(milliseconds: 84100));
    await tester.pump();
    expect(library.history.single.positionSeconds, 84);
    expect(library.history.single.episodeId, 'ep-1');
  });

  testWidgets('switching episode flushes the previous episode progress',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final library = AnimeLibraryStore(persistDelay: const Duration(hours: 1));
    await library.load();
    addTearDown(library.dispose);
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimeLibraryScope(
        store: library,
        child: AnimePlayerPage(
          meta: const SourceMeta(
            id: 'test-anime',
            name: 'Test Anime',
            script: '',
            kind: 'anime',
          ),
          animeId: 'anime-1',
          animeTitle: '测试番剧',
          episodes: const [
            Chapter(id: 'ep-1', name: '第一集'),
            Chapter(id: 'ep-2', name: '第二集'),
          ],
          index: 0,
          dependencies: dependencies,
        ),
      ),
    ));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.positionController.add(const Duration(seconds: 42));
    await tester.pump();

    // 上/下一集现在是控件行里的图标按钮,不再单独占一整行文字按钮。
    await tester.tap(find.byTooltip('下一集'));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    final persisted = jsonDecode(prefs.getString('anime.history.v1')!) as List;
    expect(persisted.single['episodeId'], 'ep-1');
    expect(persisted.single['positionSeconds'], 42);
  });

  testWidgets('shows transient playback state without replacing the video',
      (tester) async {
    for (final entry in <(PlaybackState, String)>[
      (
        const PlaybackState(
          phase: PlaybackPhase.opening,
          selectedTrack: _track,
        ),
        '正在连接视频',
      ),
      (
        const PlaybackState(
          phase: PlaybackPhase.buffering,
          selectedTrack: _track,
        ),
        '正在缓冲',
      ),
      (
        const PlaybackState(
          phase: PlaybackPhase.recovering,
          selectedTrack: _track,
          message: '正在恢复播放（1/3）',
        ),
        '正在恢复播放（1/3）',
      ),
    ]) {
      await tester.pumpWidget(_host(entry.$1));
      expect(find.byKey(const ValueKey('video-surface')), findsOneWidget);
      expect(find.text(entry.$2), findsOneWidget);
    }
  });

  testWidgets('normal playing removes transient status', (tester) async {
    await tester.pumpWidget(_host(const PlaybackState(
      phase: PlaybackPhase.playing,
      selectedTrack: _track,
    )));

    expect(find.byKey(const ValueKey('video-surface')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('正在'), findsNothing);
  });

  testWidgets('terminal failure exposes a retry command', (tester) async {
    var retried = false;
    await tester.pumpWidget(_host(
      const PlaybackState(
        phase: PlaybackPhase.failed,
        selectedTrack: _track,
        message: '播放恢复失败：连接已断开',
      ),
      onRetry: () => retried = true,
    ));

    expect(find.text('播放失败'), findsOneWidget);
    expect(find.textContaining('连接已断开'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
  });

  testWidgets('page delegates opening and readiness to the session controller',
      (tester) async {
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(
        key: ValueKey('injected-video'),
        color: Colors.black,
      ),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();

    expect(adapter.opened, [_track]);
    expect(find.text('正在连接视频'), findsOneWidget);
    adapter.playingController.add(true);
    await tester.pump();

    expect(find.byKey(const ValueKey('injected-video')), findsOneWidget);
    expect(find.text('正在连接视频'), findsNothing);
  });

  testWidgets('manual quality switch reuses the loaded list', (tester) async {
    final adapter = _PageFakeAdapter();
    var loadCalls = 0;
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async {
        loadCalls++;
        return const [_track, _track360];
      },
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.descendant(
      of: find.byType(TextButton),
      matching: find.text('480p'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('360p'));
    await tester.pump(const Duration(milliseconds: 350));

    expect(adapter.opened.last, _track360);
    expect(loadCalls, 1);
  });

  // 多数源的主清单只有一条变体。摆成一份点了没反应的选单,比直接说「只有这一种」
  // 更让人困惑 —— 那正是 608p 那条 issue 里看到的样子。
  testWidgets('a stream with one variant states its quality instead of'
      ' offering a choice', (tester) async {
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [
        VideoTrack(url: 'https://media.example.test/only.m3u8', quality: '1080P', hls: true),
      ],
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.descendant(
      of: find.byType(TextButton),
      matching: find.text('1080P'),
    ));
    await tester.pumpAndSettle();

    // 唯一清晰度仍显示读数，但不再塞进重复的设置抽屉页签。
    expect(find.text('1080P'), findsNWidgets(3));
    expect(find.text('这条流只提供这一种清晰度'), findsNothing);
  });

  // 改倍速不该盖住半个画面:右下角那颗按钮弹的是一张贴着底栏的小卡片,
  // 不是把整块抽屉拉出来。
  testWidgets('the speed button opens a card, not the whole drawer',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.text('倍速'));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);
    expect(find.text('字幕'), findsNothing); // 抽屉没被拉出来

    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(adapter.rates.last, 1.5);
    // 选完就收,读数换成刚选的那一档。
    expect(find.text('0.5x'), findsNothing);
    expect(find.text('1.5x'), findsOneWidget);
  });

  testWidgets('tapping the picture puts the card away before the chrome',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.text('倍速'));
    await tester.pumpAndSettle();
    expect(find.text('0.5x'), findsOneWidget);

    await tester.tapAt(const Offset(200, 200));
    // 双击暂停装上之后,单击要等双击的判定窗口过去才落地。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('0.5x'), findsNothing);
    // chrome 还在 —— 点外面关卡片,不该顺手把控件也收了。
    expect(find.text('倍速'), findsOneWidget);
  });

  // 「16:9 / 4:3」不是 BoxFit 能表达的:那是先把画面框成某个比例再裁。
  testWidgets('a locked ratio frames the picture before filling it',
      (tester) async {
    final adapter = _PageFakeAdapter();
    final fits = <BoxFit>[];
    await tester.pumpWidget(_playerHost(
      adapter,
      videoBuilder: (fit) {
        fits.add(fit);
        return const ColoredBox(color: Colors.black);
      },
    ));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    expect(find.byType(AspectRatio), findsNothing);
    expect(fits.last, BoxFit.contain);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16:9'));
    await tester.pumpAndSettle();

    final framed = tester.widget<AspectRatio>(find.byType(AspectRatio));
    expect(framed.aspectRatio, closeTo(16 / 9, 0.001));
    expect(fits.last, BoxFit.cover);
  });

  testWidgets('the three-dot menu keeps only subtitles and playback settings',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('字幕'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('选集'), findsNothing);
    expect(find.text('清晰度'), findsNothing);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('单集循环'), findsOneWidget);
    expect(find.text('列表循环'), findsOneWidget);
    expect(find.text('不循环'), findsOneWidget);
    expect(find.text('自动连播'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('a double tap pauses and the next one resumes', (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.playingController.add(true);
    await tester.pump();

    Future<void> doubleTap() async {
      await tester.tapAt(const Offset(300, 200));
      // 两下之间要隔开 kDoubleTapMinTime,否则第二下会被当成同一下的重复事件。
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(const Offset(300, 200));
      await tester.pumpAndSettle();
    }

    final pauses = adapter.pauseCalls;
    await doubleTap();
    expect(adapter.pauseCalls, greaterThan(pauses));

    adapter.playingController.add(false);
    await tester.pump();
    final plays = adapter.playCalls;
    await doubleTap();
    expect(adapter.playCalls, plays + 1);
  });

  // 横屏看番时口袋、手掌、袖子都在往屏幕上蹭 —— 一蹭就跳进度是最恼人的一种。
  testWidgets('locking takes the chrome away and stops the gestures',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.byTooltip('锁定屏幕'));
    await tester.pumpAndSettle();

    expect(find.text('倍速'), findsNothing);
    expect(find.byTooltip('解锁屏幕'), findsOneWidget);

    // 锁上之后横拖不该动进度。
    final seeks = adapter.seeks.length;
    await tester.drag(find.byType(AnimePlaybackSurface), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(adapter.seeks, hasLength(seeks));

    await tester.tap(find.byTooltip('解锁屏幕'));
    await tester.pumpAndSettle();
    expect(find.text('倍速'), findsOneWidget);
  });

  // 双指摆过画面之后得有路回去 —— 不然歪着的画面就一直歪着。
  testWidgets('a two-finger zoom offers a way back to the original picture',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(
      adapter,
      videoBuilder: (_) => const ColoredBox(
        key: ValueKey('host-video'),
        color: Colors.black,
      ),
    ));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    Finder wrappers() => find.ancestor(
          of: find.byKey(const ValueKey('host-video')),
          matching: find.byType(Transform),
        );
    final before = wrappers().evaluate().length;
    expect(find.byTooltip('还原画面'), findsNothing);

    final centre = tester.getCenter(find.byType(AnimePlaybackSurface));
    final first = await tester.startGesture(centre - const Offset(40, 0));
    final second = await tester.startGesture(centre + const Offset(40, 0));
    await first.moveBy(const Offset(-60, 0));
    await second.moveBy(const Offset(60, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    // 平移 + 旋转 + 缩放三层,画面确实被套起来了。
    expect(wrappers().evaluate().length, greaterThan(before));
    expect(find.byTooltip('还原画面'), findsOneWidget);

    await tester.tap(find.byTooltip('还原画面'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('还原画面'), findsNothing);
    expect(wrappers().evaluate().length, before);
  });

  testWidgets('complete offline episode bypasses online track resolution',
      (tester) async {
    final adapter = _PageFakeAdapter();
    var onlineLoads = 0;
    const offline = VideoTrack(
      url: 'file:///offline/index.m3u8',
      quality: '离线',
      hls: true,
    );
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async {
        onlineLoads++;
        return const [_track];
      },
      localTrackForEpisode: (_) => offline,
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();

    expect(adapter.opened, [offline]);
    expect(onlineLoads, 0);
  });

  testWidgets('page controls pause on drag and seek through the session',
      (tester) async {
    final adapter = _PageFakeAdapter();
    final dependencies = AnimePlayerDependencies(
      player: adapter,
      tracks: _PageFakeTracks(),
      loadTracks: (_) async => const [_track],
      videoBuilder: (_) => const ColoredBox(color: Colors.black),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: const [Chapter(id: 'ep-1', name: '第一集')],
        index: 0,
        dependencies: dependencies,
      ),
    ));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 10));
    adapter.positionController.add(const Duration(minutes: 2));
    adapter.playingController.add(true);
    await tester.pump();

    expect(find.byType(AnimePlayerControls), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(140, 0));
    await tester.pump();

    expect(adapter.pauseCalls, greaterThanOrEqualTo(1));
    expect(adapter.seeks.last, greaterThan(const Duration(minutes: 2)));
  });

  testWidgets('long press fast-forwards and releasing restores the rate',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 10));
    adapter.playingController.add(true);
    await tester.pump();

    final surface = find.byType(AnimePlaybackSurface);
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('player-boost-badge')), findsOneWidget);
    expect(adapter.rates.last, 3.0);

    await gesture.up();
    await tester.pump();
    expect(find.byKey(const Key('player-boost-badge')), findsNothing);
    expect(adapter.rates.last, 1.0);
  });

  testWidgets('horizontal drag scrubs instead of double tap seeking',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 10));
    adapter.positionController.add(const Duration(minutes: 2));
    adapter.playingController.add(true);
    await tester.pump();

    final surface = find.byType(AnimePlaybackSurface);
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 40));
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const Key('player-seek-badge')), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(adapter.seeks.last, greaterThan(const Duration(minutes: 2)));

    // 双击不再是快进/快退:两下点击只是开关控件层,不产生任何 seek。
    final before = adapter.seeks.length;
    await tester.tapAt(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 400));
    expect(adapter.seeks, hasLength(before));
  });

  // 定位按固定时长换算,不按片长的百分比。按百分比的话手指在长片里就是毒的:
  // 同一段位移,10 分钟的一集走 40 秒,24 分钟的一集要走一分半,想退回刚才那句
  // 台词根本停不住。现在无论多长的一集,划满一屏都是两分钟。
  testWidgets('a swipe covers a fixed span, not a share of the episode',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 40));
    adapter.positionController.add(const Duration(minutes: 5));
    adapter.playingController.add(true);
    await tester.pump();

    final surface = find.byType(AnimePlaybackSurface);
    final width = tester.getSize(surface).width;
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 40));
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();

    final moved = adapter.seeks.last - const Duration(minutes: 5);
    final expected = 200 / width * const Duration(minutes: 2).inMilliseconds;
    expect(moved.inMilliseconds, closeTo(expected, 900));
  });

  // 很短的片子另算:一屏两分钟会让三分钟的片子一划就到头。
  testWidgets('a very short clip scales the sweep down to stay usable',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 2));
    adapter.positionController.add(const Duration(seconds: 30));
    adapter.playingController.add(true);
    await tester.pump();

    final surface = find.byType(AnimePlaybackSurface);
    final width = tester.getSize(surface).width;
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveBy(Offset(width / 2, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();

    // 半屏 = 量程的一半 = 片长的四分之一,而不是直接冲到片尾。
    final moved = adapter.seeks.last - const Duration(seconds: 30);
    expect(moved, lessThan(const Duration(seconds: 40)));
    expect(moved, greaterThan(const Duration(seconds: 20)));
  });

  // 一整屏高走完整个量程。原来是六成屏高,手一抖就从正常听到静音。
  testWidgets('half a screen of vertical travel moves half the volume',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 24));
    adapter.playingController.add(true);
    await tester.pump();

    final surface = find.byType(AnimePlaybackSurface);
    final height = tester.getSize(surface).height;
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveBy(Offset(0, height / 2));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump();

    expect(adapter.volumes.last, closeTo(50, 6));
  });

  testWidgets('finishing an episode rolls on to the next one', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final adapter = _PageFakeAdapter();
    final loaded = <String>[];
    await tester.pumpWidget(_playerHost(
      adapter,
      episodes: const [
        Chapter(id: 'ep-1', name: '第一集'),
        Chapter(id: 'ep-2', name: '第二集'),
      ],
      onLoadTracks: loaded.add,
    ));
    await tester.pump();
    expect(loaded, ['ep-1']);

    adapter.completedController.add(true);
    await tester.pump();
    await tester.pump();

    expect(loaded, ['ep-1', 'ep-2']);
    expect(find.textContaining('第二集'), findsWidgets);
  });

  testWidgets('single loop reopens the current episode', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final adapter = _PageFakeAdapter();
    final loaded = <String>[];
    await tester.pumpWidget(_playerHost(
      adapter,
      episodes: const [
        Chapter(id: 'ep-1', name: '第一集'),
        Chapter(id: 'ep-2', name: '第二集'),
      ],
      onLoadTracks: loaded.add,
    ));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单集循环'));
    await tester.pump();

    adapter.completedController.add(true);
    await tester.pump();
    await tester.pump();

    expect(loaded, ['ep-1', 'ep-1']);
  });

  // 会话层一度只在换阶段(缓冲开停、播放暂停)时才发出位置,播放途中进度条是
  // **不动的**。这里盯着读数,别再退回去。
  testWidgets('elapsed readout follows the playback position', (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 10));
    adapter.playingController.add(true);
    await tester.pump();

    // 当前 / 总时长是同一个 Text,挨在一起显示。
    adapter.positionController.add(const Duration(seconds: 65));
    await tester.pump();
    expect(find.text('01:05 / 10:00'), findsOneWidget);

    adapter.positionController.add(const Duration(seconds: 66));
    await tester.pump();
    expect(find.text('01:06 / 10:00'), findsOneWidget);
  });

  // 源给的分集名常常已经含番剧名,再拼一次就是「龙与虎 · 第1话 龙与虎」。
  testWidgets('分集名已经带了番剧名就不再拼一遍', (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(
      adapter,
      episodes: const [Chapter(id: 'ep-1', name: '第1话 测试番剧')],
    ));
    await tester.pump();

    expect(find.text('第1话 测试番剧'), findsOneWidget);
    expect(find.textContaining('测试番剧 · '), findsNothing);
  });

  testWidgets('分集名与番剧名无关时照常拼', (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(
      adapter,
      episodes: const [Chapter(id: 'ep-1', name: '第一集')],
    ));
    await tester.pump();

    expect(find.text('测试番剧 · 第一集'), findsOneWidget);
  });

  testWidgets('keyboard drives seek, volume, mute and play', (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 10));
    adapter.playingController.add(true);
    await tester.pump();
    adapter.positionController.add(const Duration(minutes: 2));
    await tester.pump();

    // 前进比后退跨得大 —— 等距的 ±10 会让人在两个点之间来回弹。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(adapter.seeks.last, const Duration(minutes: 2, seconds: 15));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(adapter.seeks.last, const Duration(minutes: 2, seconds: 10));

    // Shift+→ 跨过整段片头。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(adapter.seeks.last, const Duration(minutes: 3, seconds: 40));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(adapter.volumes.last, 95);

    // M 静音再按一次要回到静音前的音量,而不是傻乎乎地回到 100。
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(adapter.volumes.last, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(adapter.volumes.last, 95);

    final pauses = adapter.pauseCalls;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(adapter.pauseCalls, greaterThan(pauses));
  });

  testWidgets('vertical drag changes the volume', (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.durationController.add(const Duration(minutes: 10));
    adapter.playingController.add(true);
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(AnimePlaybackSurface)),
    );
    await tester.pump(const Duration(milliseconds: 40));
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(const Offset(0, 40)); // 往下 = 调小
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const Key('player-adjust-badge')), findsOneWidget);
    await gesture.up();
    await tester.pump();

    expect(adapter.volumes, isNotEmpty);
    expect(adapter.volumes.last, lessThan(100));
    // 竖着拖不该顺带把进度也拖了。
    expect(adapter.seeks, isEmpty);
  });

  testWidgets('subtitle panel offers the source subtitles and applies one',
      (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter, tracks: const [_subtitled]));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('字幕'));
    await tester.pumpAndSettle();

    expect(find.text('关闭字幕'), findsOneWidget);
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();

    expect(adapter.subtitlePicks.single.url,
        'https://media.example.test/zh.vtt');
  });

  testWidgets('an episode without subtitles says so', (tester) async {
    final adapter = _PageFakeAdapter();
    await tester.pumpWidget(_playerHost(adapter));
    await tester.pump();
    adapter.playingController.add(true);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('字幕'));
    await tester.pumpAndSettle();

    expect(find.text('这一集没有字幕'), findsOneWidget);
  });
}

Widget _playerHost(
  _PageFakeAdapter adapter, {
  List<Chapter> episodes = const [Chapter(id: 'ep-1', name: '第一集')],
  List<VideoTrack> tracks = const [_track],
  void Function(String episodeId)? onLoadTracks,
  Widget Function(BoxFit fit)? videoBuilder,
}) =>
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData(extensions: const [
        AppTokens(palette: AppPalette.dark),
      ]),
      home: AnimePlayerPage(
        meta: const SourceMeta(
          id: 'test-anime',
          name: 'Test Anime',
          script: '',
          kind: 'anime',
        ),
        animeId: 'anime-1',
        animeTitle: '测试番剧',
        episodes: episodes,
        index: 0,
        dependencies: AnimePlayerDependencies(
          player: adapter,
          tracks: _PageFakeTracks(),
          loadTracks: (episodeId) async {
            onLoadTracks?.call(episodeId);
            return tracks;
          },
          videoBuilder: videoBuilder ??
              (_) => const ColoredBox(color: Colors.black),
        ),
      ),
    );

class _PageFakeAdapter implements PlayerAdapter {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final bufferingController = StreamController<bool>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration>.broadcast(sync: true);
  final bufferController = StreamController<Duration>.broadcast(sync: true);
  final completedController = StreamController<bool>.broadcast(sync: true);
  final errorController = StreamController<Object>.broadcast(sync: true);
  final subtitleController =
      StreamController<List<SubtitleOption>>.broadcast(sync: true);
  final opened = <VideoTrack>[];
  final openStarts = <Duration>[];
  final seeks = <Duration>[];
  final volumes = <double>[];
  final subtitlePicks = <SubtitleOption>[];
  int pauseCalls = 0;
  int playCalls = 0;

  @override
  Stream<bool> get playing => playingController.stream;
  @override
  Stream<bool> get buffering => bufferingController.stream;
  @override
  Stream<Duration> get position => positionController.stream;
  @override
  Stream<Duration> get duration => durationController.stream;
  @override
  Stream<Duration> get buffer => bufferController.stream;
  @override
  Stream<bool> get completed => completedController.stream;
  @override
  Stream<Object> get errors => errorController.stream;
  @override
  Stream<List<SubtitleOption>> get subtitles => subtitleController.stream;
  @override
  Future<void> open(VideoTrack track, {Duration startAt = Duration.zero}) async {
    opened.add(track);
    openStarts.add(startAt);
  }
  @override
  Future<void> rebuildDecoder(Duration resumePosition) async {}
  @override
  Future<void> pause() async => pauseCalls++;
  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  final rates = <double>[];
  @override
  Future<void> setRate(double rate) async => rates.add(rate);
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setSubtitle(SubtitleOption option) async =>
      subtitlePicks.add(option);
  @override
  Future<void> dispose() async {
    await playingController.close();
    await bufferingController.close();
    await positionController.close();
    await durationController.close();
    await bufferController.close();
    await completedController.close();
    await errorController.close();
    await subtitleController.close();
  }
}

class _PageFakeTracks implements PlaybackTrackProvider {
  @override
  VideoTrack? alternateLine(VideoTrack current, List<VideoTrack> available) =>
      null;
  @override
  VideoTrack? lowerQuality(VideoTrack current, List<VideoTrack> available) =>
      null;
  @override
  VideoTrack? matchRefreshed(VideoTrack current, List<VideoTrack> refreshed) =>
      refreshed.firstOrNull;
  @override
  Future<List<VideoTrack>> refresh() async => const [_track];
}
