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

  test('续作 / 外传不误合', () {
    expect(sameWork('斗罗大陆', '斗罗大陆2绝世唐门'), false);
    expect(sameWork('刀剑神域', '刀剑神域外传'), false);
    expect(sameWork('进击的巨人', '进击的巨人最终季'), false);
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
}
