import 'package:flutter_test/flutter_test.dart';
import 'package:dream_manga_reader/core/source/chapter_number.dart';

/// 覆盖跨源对齐键 parseChapterNumber:各种章名 → 话数。
void main() {
  double? n(String s) => parseChapterNumber(s);

  test('第N话/章/回/集', () {
    expect(n('第1话'), 1);
    expect(n('第1050话'), 1050);
    expect(n('第25章'), 25);
    expect(n('第7回'), 7);
    expect(n('第3集'), 3);
    expect(n('第100话 完结'), 100);
  });

  test('繁体「話」与前后修饰', () {
    expect(n('第12話'), 12);
    expect(n('连载 第88话'), 88);
    expect(n('更新至第200话'), 200);
  });

  test('.5 番外', () {
    expect(n('第10.5话'), 10.5);
    expect(n('第10.5話'), 10.5);
  });

  test('全角数字', () {
    expect(n('第１２話'), 12);
    expect(n('第１２．５話'), 12.5);
  });

  test('英文源 Chapter / Ch / Ep / #', () {
    expect(n('Chapter 12'), 12);
    expect(n('chapter 7.5'), 7.5);
    expect(n('Ch.7'), 7);
    expect(n('Ch 7'), 7);
    expect(n('Episode 3'), 3);
    expect(n('#5'), 5);
    expect(n('EP 9'), 9);
  });

  test('纯数字章名', () {
    expect(n('1050'), 1050);
    expect(n('1050.5'), 1050.5);
    expect(n('  42  '), 42);
  });

  test('优先「话」而非卷号', () {
    expect(n('第3卷 第5话'), 5);
    expect(n('Vol.2 Chapter 8'), 8);
  });

  test('开头数字 =「序号.标题」格式(首选)', () {
    expect(n('46.是勇者就上100层'), 46); // 点分隔,标题里的 100 不干扰
    expect(n('08 新的开始'), 8); // 空格分隔 + 前导零
    expect(n('第46 上'), 46); // 有「第」无「话」
    expect(n('51、消失的第299层'), 51); // 顿号分隔;标题里「第299层」无话标记
    expect(n('12.3年后的重逢'), 12); // 点后是数字开头的标题正文 → 只取序号
    expect(n('12.5 番外'), 12.5); // 小数后是空白 → 真半话
    expect(n('12.5'), 12.5);
    expect(n('12.5话'), 12.5); // 无「第」半话:小数后是话标记 → 半话
    expect(n('34.5回'), 34.5);
  });

  test('裸序号后空格是标题分隔:标题首字撞单位字不误拒', () {
    expect(n('08 月光下的少女'), 8);
    expect(n('51 周而复始'), 51);
    expect(n('33 年少时代'), 33);
  });

  test('开头数字但后跟卷/季/日期/时长单位 → 不是话数', () {
    expect(n('第2卷'), isNull);
    expect(n('第3季'), isNull);
    expect(n('第 2 卷'), isNull); // 带「第」才跨空格看单位(mangadex 卷名)
    expect(n('2023年总集篇'), isNull);
    expect(n('100天后会死的鳄鱼'), isNull);
    expect(n('24小时营业'), isNull); // 多字时长单位
    expect(n('3个月后'), isNull);
  });

  test('无话数 → null(番外/序章/纯标题)', () {
    expect(n('番外篇'), isNull);
    expect(n('序章'), isNull);
    expect(n('特别篇'), isNull);
    expect(n('后记'), isNull);
    expect(n(''), isNull);
  });

  test('英文单词里的 ch/ep 不误命中(词边界)', () {
    expect(n('Punch'), isNull); // 无数字
    expect(n('Punch time'), isNull);
  });

  test('合并章取一个数(区间尽力而为)', () {
    // 「第10-11话」:第10 后接「-」不匹配 第N话,退到 (\d+)话 命中 11 —— 取到区间端点即可。
    expect(n('第10-11话'), anyOf(10, 11));
  });
}
