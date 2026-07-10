import 'package:flutter_test/flutter_test.dart';
import 'package:dream_manga_reader/core/source/title_match.dart';

/// 覆盖跨源「同一作品」判定:容繁简 + 副标题,但不误合续作/外传。
void main() {
  test('繁简变体归为同一作品(多数字相同时)', () {
    expect(sameWork('穿越者的幸运礼', '穿越者的幸運禮'), true); // 差 2 字
    expect(sameWork('我的英雄学院', '我的英雄學院'), true); // 差 1 字
  });

  test('已知局限:短标题且几乎全繁简不同 → 无法归一(需 OpenCC 字表,暂不引原生依赖)', () {
    expect(sameWork('斗罗大陆', '鬥羅大陸'), false); // 4 字里 3 字繁简不同,仅「大」相同
  });

  test('括号副标题被剥离后归一', () {
    expect(sameWork('穿越者的幸运礼', '穿越者的幸运礼[连载]'), true);
    expect(sameWork('某漫画（完结）', '某漫画'), true);
    expect(sameWork('作品【全彩版】', '作品'), true);
  });

  test('完全相同 / 全半角 / 大小写', () {
    expect(sameWork('One Piece', 'ONE PIECE'), true);
    expect(sameWork('Ｌｖ.９９９', 'Lv.999'), true);
  });

  test('续作 / 外传 / 卷号后缀不误合(含长基名短后缀)', () {
    expect(sameWork('斗罗大陆', '斗罗大陆2绝世唐门'), false);
    expect(sameWork('刀剑神域', '刀剑神域外传'), false);
    expect(sameWork('进击的巨人', '进击的巨人最终季'), false);
    expect(sameWork('进击的巨人', '进击的巨人外传'), false); // 5 基名 + 2 后缀
    expect(sameWork('穿越者的幸运礼', '穿越者的幸运礼外传'), false); // 7 基名 + 2 后缀
    expect(sameWork('某某某某某某某某某某', '某某某某某某某某某某2'), false); // 10 基名 + 1 后缀
  });

  test('不同作品不误合', () {
    expect(sameWork('火影忍者', '海贼王'), false);
    expect(sameWork('我的妹妹', '我的弟弟'), false);
    expect(sameWork('火影忍者', '火影新传'), false);
  });

  test('空标题永不同作', () {
    expect(sameWork('', ''), false);
    expect(sameWork('！！！', '？？？'), false);
  });

  // 多源同名去重键:繁体折成简体后归一,繁简变体得到同一 key(截图里的重复卡就靠它合并)。
  group('dedupKey 繁简折叠', () {
    void same(String a, String b) =>
        expect(dedupKey(a), dedupKey(b), reason: '「$a」应与「$b」同 key');

    test('截图里的重复卡对', () {
      same('绝世武神', '絕世武神');
      same('我的妻子有点可怕', '我的妻子有點可怕');
      same('靠山满天飞的英雄谭', '靠山滿天飛的英雄譚'); // 满/飞/谭 三字繁简不同,sameCoreKey 接不住
      same('小红帽的狼徒弟', '小紅帽的狼徒弟');
      same('取得骑龙执照的女高中生', '取得騎龍執照的女高中生');
    });

    test('高繁简差异标题(sameCoreKey 的已知局限)也能折', () {
      same('斗罗大陆', '鬥羅大陸'); // 4 字里 3 字繁简不同
    });

    test('不同的书 key 不同', () {
      expect(dedupKey('火影忍者') == dedupKey('海贼王'), false);
    });
  });
}
