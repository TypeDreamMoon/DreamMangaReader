// 书架滚动的**可复现帧耗时测量**(方案 B:本机自动化,不用手滚屏幕)。
//
// 为什么是这套:书架页的真实渲染路径 = 毛玻璃顶栏(BackdropFilter) + 外壳侧栏
// (BackdropFilter) + 瀑布流(SliverMasonryGrid) + 逐项入场动画(FadeSlideIn) +
// 封面解码(SourceImage → CachedNetworkImage)。这里把**真的 LibraryPage** 装进真的
// Scopes,只把数据换成合成的,于是滚动成本与线上一致、又能重复对比。
//
// 数字只有在 **profile 模式**下才有意义(debug 是 JIT + 断言):
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/scroll_profile_test.dart \
//     --profile --no-dds -d <device> --dart-define=PROFILE_LABEL=baseline
//
// `--no-dds` 是必须的:`watchPerformance` 要自己连 VM Service 抓时间线,开了 DDS
// 它连的是个过期地址(报 "Failed to connect to VM Service … try adding --no-dds")。
//
// 可调项(--dart-define):
//   PROFILE_LABEL   本次跑的标签,进 reportKey,便于区分 baseline / 改后
//   PROFILE_ITEMS   收藏条数(默认 60)
//   PROFILE_COVER   封面基址(默认 picsum 的 800×1200 JPEG;必须 HTTPS ——
//                   本 App 的 networkSecurityConfig 默认禁明文,见 android/.../xml)
//   PROFILE_ROUNDS  测量轮数(默认 5)
import 'package:dream_manga_reader/app/anime_library_store.dart';
import 'package:dream_manga_reader/app/library_store.dart';
import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/app/source_controller.dart';
import 'package:dream_manga_reader/app/theme/app_theme.dart';
import 'package:dream_manga_reader/features/library/library_page.dart';
import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _label = String.fromEnvironment('PROFILE_LABEL', defaultValue: 'run');
const int _items = int.fromEnvironment('PROFILE_ITEMS', defaultValue: 60);
const int _rounds = int.fromEnvironment('PROFILE_ROUNDS', defaultValue: 5);
const String _coverBase = String.fromEnvironment(
  'PROFILE_COVER',
  defaultValue: 'https://picsum.photos/800/1200',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('书架滚动:帧耗时汇总', (tester) async {
    // 每次跑都换 nonce:URL 不同 → 磁盘缓存不命中,两次跑做的功一样(可对比)。
    final nonce = DateTime.now().millisecondsSinceEpoch;
    final covers = [
      for (var i = 0; i < _items; i++) '$_coverBase?random=$i&run=$nonce',
    ];

    final fixture = await _Fixture.create(covers: covers);
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    // 第 0 遍:**扫一遍整个列表** —— 让 60 个条目都进过屏,封面因此下载到磁盘缓存、
    // 解码一遍。这一遍不测,只是为了后面测的是「解码 + 渲染」而不是「下载」。
    final extent = await _sweepWholeList(tester);
    final decoded = PaintingBinding.instance.imageCache.currentSize;
    debugPrint('[profile] 列表可滚高度=${extent.toStringAsFixed(0)}px;'
        ' 扫完后 ImageCache 在位张数=$decoded');
    // 冒烟闸门:书架真的滚得动才继续 —— 收藏被跨源去重折叠掉时这里会先响,
    // 免得把「空态页的帧耗时」当成滚动数据交上去。
    expect(extent, greaterThan(800),
        reason: '书架没有可滚内容(收藏是不是被去重折成一张卡了?)');

    await binding.watchPerformance(
      () => _dragOscillate(tester, downSwipes: 4, upSwipes: 4),
      reportKey: 'warmup_$_label',
    );
    _printSummary(binding, 'warmup_$_label');

    await binding.watchPerformance(
      () => _dragOscillate(tester, downSwipes: _rounds, upSwipes: _rounds),
      reportKey: 'shelf_scroll_$_label',
    );
    _printSummary(binding, 'shelf_scroll_$_label');

    // 对照场景:同一个 App、同一台设备,滚一个**纯文字**长列表。
    // 它是这台设备的「光栅地板」—— 若它的 raster 也在 40ms 量级,说明模拟器的
    // 渲染路径本身就这么慢,书架那几条优化在它上面量不出差别(只能上真机量)。
    await tester.pumpWidget(_plainListHost());
    await tester.pumpAndSettle();
    await binding.watchPerformance(
      () => _dragOscillate(tester, downSwipes: 4, upSwipes: 4),
      reportKey: 'control_plain_list_$_label',
    );
    _printSummary(binding, 'control_plain_list_$_label');

    // 冒烟断言:封面确实进过内存缓存(否则测的是空态页)。
    expect(decoded, greaterThan(5),
        reason: '封面基本没解码成功 —— 检查 PROFILE_COVER 可达性与网络');
  });
}

/// 对照场景:400 行纯文字 + 色块的懒加载列表(没有图片、没有模糊、没有阴影)。
///
/// 它测的是「这台设备滚一条最简单的列表要多少 raster」—— 拿它当分母,才能判断
/// 书架那些数字里有多少是内容成本、多少是设备地板。
Widget _plainListHost() => MaterialApp(
      theme: buildTheme(AppThemeVariant.light),
      home: ListView.builder(
        itemCount: 400,
        itemExtent: 56,
        itemBuilder: (_, i) => ColoredBox(
          color: i.isEven ? const Color(0xFF202020) : const Color(0xFF2A2A2A),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('控制行 $i'),
            ),
          ),
        ),
      ),
    );

/// 从顶滚到底再滚回顶,把整条列表走一遍(每 500px 一帧)。
///
/// 用 `jumpTo` 而不是手势:目的是「让所有条目都建过一次」,不是模拟手感。
/// 返回列表的可滚高度(便于确认扫描真的覆盖了全部条目)。
Future<double> _sweepWholeList(WidgetTester tester) async {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  final position = state.position;
  final extent = position.maxScrollExtent;
  for (var off = 0.0; off < extent; off += 500) {
    position.jumpTo(off);
    await tester.pump(const Duration(milliseconds: 32));
  }
  position.jumpTo(extent);
  await tester.pump(const Duration(milliseconds: 64));
  for (var off = extent; off > 0; off -= 500) {
    position.jumpTo(off);
    await tester.pump(const Duration(milliseconds: 32));
  }
  position.jumpTo(0);
  await tester.pumpAndSettle();
  return extent;
}

/// 把 reportData 里那一份汇总打成一行,方便直接读 job 输出。
void _printSummary(IntegrationTestWidgetsFlutterBinding binding, String key) {
  final data = binding.reportData?[key];
  if (data is! Map) {
    debugPrint('[profile] $key: 没有汇总(见 reportData)');
    return;
  }
  String ms(Object? v) =>
      v is num ? '${v.toStringAsFixed(2)}ms' : 'n/a';
  debugPrint(
    '[profile] $key | '
    'UI avg=${ms(data['average_frame_build_time_millis'])} '
    'p90=${ms(data['90th_percentile_frame_build_time_millis'])} '
    'p99=${ms(data['99th_percentile_frame_build_time_millis'])} '
    'worst=${ms(data['worst_frame_build_time_millis'])} '
    'missed=${data['missed_frame_build_budget_count']} | '
    'RASTER avg=${ms(data['average_frame_rasterizer_time_millis'])} '
    'p90=${ms(data['90th_percentile_frame_rasterizer_time_millis'])} '
    'p99=${ms(data['99th_percentile_frame_rasterizer_time_millis'])} '
    'worst=${ms(data['worst_frame_rasterizer_time_millis'])} '
    'missed=${data['missed_frame_rasterizer_budget_count']} | '
    'frames=${data['frame_count']}',
  );
}

/// 手指拖动往复:[downSwipes] 次下滑 + [upSwipes] 次上滑,每步一帧。
///
/// 比 `fling` 更接近真实拖屏:每次滑动 40 帧 × 24px ≈ 960px(手机上一屏多一点),
/// 往复幅度刻意大于 ImageCache 能装下的张数 —— 这样滚回去时必然发生
/// 「驱逐 + 重新解码」,正是用户抱怨的那段成本。
Future<void> _dragOscillate(
  WidgetTester tester, {
  required int downSwipes,
  required int upSwipes,
}) async {
  final view = tester.view;
  final centre = Offset(view.physicalSize.width / view.devicePixelRatio / 2,
      view.physicalSize.height / view.devicePixelRatio / 2);
  const step = 24.0;
  Future<void> swipe(double dir) async {
    final gesture = await tester.startGesture(centre);
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(Offset(0, -step * dir));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
  }

  for (var i = 0; i < downSwipes; i++) {
    await swipe(1);
  }
  for (var i = 0; i < upSwipes; i++) {
    await swipe(-1);
  }
}

class _Fixture {
  _Fixture({
    required this.manga,
    required this.novel,
    required this.anime,
    required this.sources,
  });

  final LibraryStore manga;
  final NovelLibraryStore novel;
  final AnimeLibraryStore anime;
  final SourceController sources;

  static Future<_Fixture> create({required List<String> covers}) async {
    SharedPreferences.setMockInitialValues(const {});
    final manga = LibraryStore();
    final novel = NovelLibraryStore();
    final anime = AnimeLibraryStore(persistDelay: Duration.zero);
    final sources = SourceController();
    await manga.load();
    await novel.load();
    await anime.load();

    for (var i = 0; i < covers.length; i++) {
      manga.toggleFavorite(FavoriteEntry(
        sourceId: 'perf-source',
        mangaId: 'perf-$i',
        // 标题**逐项加长**:跨源去重(`sameCoreKey`)是「等长 + 70% 字符重叠」算同一
        // 作品,只差一位数字的 60 个标题重叠 6/7=0.86 会被折成一张卡(实测 60 → 2),
        // 那样书架就是空的、量不出东西。
        title: '性能作品${'测' * (i + 1)}',
        cover: covers[i],
        addedAt: 1000000 + i,
      ));
    }
    // 历史横条也要有内容(它自己是一条横向 ListView)。
    for (var i = 0; i < 12; i++) {
      manga.markProgress(
        sourceId: 'perf-source',
        mangaId: 'history-$i',
        title: '历史作品 ${i + 1}',
        chapterId: 'ch-$i',
        chapterName: '第 ${i + 1} 话',
        page: 3,
        total: 20,
        nowMs: 2000000 + i,
      );
    }
    await manga.flushPending();
    await novel.flushPending();
    await anime.flushPending();

    return _Fixture(
        manga: manga, novel: novel, anime: anime, sources: sources);
  }

  Widget host() => MaterialApp(
        theme: buildTheme(AppThemeVariant.light),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: LibraryScope(
          store: manga,
          child: NovelLibraryScope(
            store: novel,
            child: AnimeLibraryScope(
              store: anime,
              child: SourceScope(controller: sources, child: const LibraryPage()),
            ),
          ),
        ),
      );

  void dispose() {
    manga.dispose();
    novel.dispose();
    anime.dispose();
    sources.dispose();
  }
}
