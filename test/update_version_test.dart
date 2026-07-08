import 'package:flutter_test/flutter_test.dart';
import 'package:dream_manga_reader/core/update/update_service.dart';

/// 覆盖 UpdateService 的版本比较(此前忽略 -beta.N 后缀,导致 beta.3 检测不到 beta.4)。
void main() {
  int cmp(String a, String b) => UpdateService.compareVersions(a, b);

  test('同 base 的预发布逐级比较(核心 bug)', () {
    expect(cmp('v1.0.0-beta.4', '1.0.0-beta.3'), greaterThan(0)); // beta.4 > beta.3
    expect(cmp('1.0.0-beta.3', 'v1.0.0-beta.4'), lessThan(0));
  });

  test('数字段按数值比,不按字典序', () {
    expect(cmp('1.0.0-beta.10', '1.0.0-beta.9'), greaterThan(0)); // 10 > 9
  });

  test('正式版 > 同 base 预发布', () {
    expect(cmp('1.0.0', '1.0.0-beta.99'), greaterThan(0));
    expect(cmp('1.0.0-rc.1', '1.0.0'), lessThan(0));
  });

  test('预发布通道排序 alpha < beta < rc', () {
    expect(cmp('1.0.0-alpha.5', '1.0.0-beta.1'), lessThan(0));
    expect(cmp('1.0.0-beta.1', '1.0.0-rc.1'), lessThan(0));
  });

  test('base 版本号优先', () {
    expect(cmp('1.0.1-beta.1', '1.0.0'), greaterThan(0));
    expect(cmp('2.0.0-beta.1', '1.9.9'), greaterThan(0));
  });

  test('相等(忽略 v 前缀 + build 元数据)', () {
    expect(cmp('v1.0.0-beta.3', '1.0.0-beta.3+7'), 0);
    expect(cmp('1.2.3', 'v1.2.3'), 0);
  });

  test('isPrerelease', () {
    expect(UpdateService.isPrerelease('1.0.0-beta.4'), isTrue);
    expect(UpdateService.isPrerelease('v1.0.0-rc.1'), isTrue);
    expect(UpdateService.isPrerelease('1.0.0'), isFalse);
  });
}
