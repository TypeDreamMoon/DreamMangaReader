import 'package:dream_manga_reader/core/bili/bili_wbi.dart';
import 'package:flutter_test/flutter_test.dart';

/// WBI 签名单测。mixin_key 用社区文档(bilibili-API-collect docs/misc/sign/wbi)的官方样例
/// 向量校验算法正确;sign 校验确定性 + 格式 + 排序/滤字符行为。
void main() {
  test('biliKeyFromUrl 取文件名去扩展名', () {
    expect(
        biliKeyFromUrl(
            'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png'),
        '7cd084941338484aae1ad9425b84077c');
    expect(
        biliKeyFromUrl(
            'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png'),
        '4932caff0ff746eab6f01bf08b70ac45');
  });

  test('biliMixinKey 官方样例向量', () {
    // 文档样例:img_key + sub_key → mixin_key(取重排后前 32 位)。
    const img = '7cd084941338484aae1ad9425b84077c';
    const sub = '4932caff0ff746eab6f01bf08b70ac45';
    expect(biliMixinKey(img, sub), 'ea1db124af3c7062474693fa704f4ff8');
  });

  test('biliWbiSign 加 wts + w_rid、确定、md5 32 位', () {
    const mixin = 'ea1db124af3c7062474693fa704f4ff8';
    final a = biliWbiSign({'foo': '114', 'bar': '514', 'baz': 1919810}, mixin,
        nowSec: 1702204169);
    expect(a['wts'], '1702204169');
    expect(a['w_rid'], matches(RegExp(r'^[0-9a-f]{32}$')));
    // 相同输入 → 相同签名。
    final b = biliWbiSign({'baz': 1919810, 'foo': '114', 'bar': '514'}, mixin,
        nowSec: 1702204169);
    expect(b['w_rid'], a['w_rid']); // 排序无关,结果一致
    // 时间不同 → 签名不同。
    final c = biliWbiSign({'foo': '114'}, mixin, nowSec: 1702204170);
    final d = biliWbiSign({'foo': '114'}, mixin, nowSec: 1702204171);
    expect(c['w_rid'], isNot(d['w_rid']));
  });

  test('过滤 !\'()* 字符', () {
    const mixin = 'ea1db124af3c7062474693fa704f4ff8';
    final withSpecial =
        biliWbiSign({'k': "a!'()*b"}, mixin, nowSec: 1700000000);
    final clean = biliWbiSign({'k': 'ab'}, mixin, nowSec: 1700000000);
    expect(withSpecial['w_rid'], clean['w_rid']); // 滤后等价
  });

  // 与官方参考实现(urllib.parse.urlencode + md5)逐字节对齐的固定向量:
  // 空格→`+`、CJK→大写百分号编码、滤字符,三种情形都必须与 Python 一致。
  test('w_rid 对齐 Python 参考实现(固定向量)', () {
    const mixin = 'ea1db124af3c7062474693fa704f4ff8';
    expect(
        biliWbiSign({'keyword': 'hello world', 'page': 1}, mixin,
            nowSec: 1700000000)['w_rid'],
        'e3e99dc6c72b4b578e8e3697de239205'); // 空格
    expect(
        biliWbiSign({'keyword': '间谍过家家'}, mixin, nowSec: 1700000000)['w_rid'],
        '7cde3903e0efd00ea7c8a42fc3a81059'); // CJK
    expect(
        biliWbiSign({'k': "a!'()*b"}, mixin, nowSec: 1700000000)['w_rid'],
        '56d78df82314b884ee61bd02c25ef6c5'); // 滤字符
  });
}
