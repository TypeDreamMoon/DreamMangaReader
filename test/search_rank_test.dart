import 'package:dream_manga_reader/core/source/chinese_fold.dart';
import 'package:dream_manga_reader/core/source/search_rank.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ChineseFold.load(); // dedupKey 依赖 OpenCC 繁简字表资源
  });

  group('searchRelevance', () {
    const q = '穿越者的幸运礼';

    test('同名精确命中 = 3(含繁简/空格差异)', () {
      expect(searchRelevance('穿越者的幸运礼', q), 3);
      expect(searchRelevance('穿越者的幸運禮', q), 3); // 繁体
      expect(searchRelevance(' 穿越者的幸运礼 ', q), 3); // 空白
    });

    test('同作品(带括号装饰)= 2', () {
      // coreTitle 只剥括号装饰;冒号副标题可能是续作,故意不并(落到包含=1)。
      expect(searchRelevance('穿越者的幸运礼【全彩】', q), 2);
    });

    test('互相包含 = 1', () {
      expect(searchRelevance('穿越者', q), 1); // 查询包含标题
      expect(searchRelevance('我在异世界当穿越者的幸运礼商人的日子', q), 1); // 标题包含查询
      expect(searchRelevance('穿越者的幸运礼:新的开始', q), 1); // 冒号副标题(可能是续作)
    });

    test('模糊召回的无关结果 = 0', () {
      expect(searchRelevance('异世界开局就无敌', q), 0);
      expect(searchRelevance('幸运星', q), 0);
    });

    test('浏览模式(空查询)恒 0', () {
      expect(searchRelevance('穿越者的幸运礼', ''), 0);
    });

    test('排序性质:精确命中永远压过先到的模糊结果', () {
      // 模拟到达顺序:模糊 → 包含 → 精确;按 rank 降序稳定插排后精确应在第一位。
      final arrivals = ['异世界开局就无敌', '穿越者', '穿越者的幸运礼', '幸运星'];
      final results = <({String title, int rank})>[];
      for (final t in arrivals) {
        final r = (title: t, rank: searchRelevance(t, q));
        var i = results.length;
        while (i > 0 && results[i - 1].rank < r.rank) {
          i--;
        }
        results.insert(i, r);
      }
      expect(results.first.title, '穿越者的幸运礼');
      expect(results.map((e) => e.rank).toList(), [3, 1, 0, 0]);
      // 同分段内保持到达顺序(稳定)。
      expect(results[2].title, '异世界开局就无敌');
      expect(results[3].title, '幸运星');
    });
  });
}
