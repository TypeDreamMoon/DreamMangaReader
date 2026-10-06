import 'package:dream_manga_reader/app/theme/app_colors.dart';
import 'package:dream_manga_reader/ui/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真实版本说明的语法子集渲染 MarkdownView,验证:各块被识别、正文可见、
/// 记号被消化(不再原样显示 `##`/`**`/`|`)、链接可点、行内代码保留内容。
Widget _host(String md) => MaterialApp(
      theme: ThemeData(
          extensions: const [AppTokens(palette: AppPalette.oled)]),
      home: Scaffold(body: SingleChildScrollView(child: MarkdownView(md))),
    );

void main() {
  const notes = '''
# 梦漫 v1.2.0

围绕**多源**的一次更新。

## ✨ 新功能

- **自动换源**:源挂了自动找同名书
- 逐话选源:点 `源角标` 直接打开
  - 嵌套项也要能显示

## 📦 安装

| 平台 | 文件 |
|---|---|
| Windows | setup.exe |
| Android | universal.apk |

> 升级遇「无法降级」请重试,见 [发布页](https://github.com/TypeDreamMoon/DreamMangaReader)。

---

普通段落收尾,含 `AppInfo.version` 这种 snake 无关的行内代码。
''';

  testWidgets('渲染不抛异常且识别各块', (tester) async {
    await tester.pumpWidget(_host(notes));
    await tester.pump();

    // 标题正文可见,但 Markdown 记号已消化(整棵树里不应再出现裸 ## / ** / 表格管道)。
    expect(find.textContaining('新功能'), findsWidgets);
    expect(find.textContaining('自动换源'), findsWidgets);
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('**自动换源**'), findsNothing);
    expect(find.textContaining('|'), findsNothing);

    // 表格单元格、行内代码内容都以纯文本落地。
    expect(find.textContaining('Windows'), findsWidgets);
    expect(find.textContaining('setup.exe'), findsWidgets);
    expect(find.textContaining('AppInfo.version'), findsWidgets);

    // 分隔线渲染成 Divider。
    expect(find.byType(Divider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空说明与纯文本都安全', (tester) async {
    await tester.pumpWidget(_host(''));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host('就一行没有任何标记的文本'));
    await tester.pump();
    expect(find.textContaining('就一行没有任何标记的文本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未闭合记号原样退化,不吞字符', (tester) async {
    await tester.pumpWidget(_host('这里有 **没闭合的粗体 和 `没闭合代码'));
    await tester.pump();
    // 文本内容仍在(退化为普通文本),不崩。
    expect(find.textContaining('没闭合的粗体'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  // 回归:# 后无空格的行(CJK 常写 ##安装)以前会死循环卡死 UI 线程。
  testWidgets('# 无空格 / 7+ 井号 不死循环', (tester) async {
    for (final bad in ['正文\n#42', '##安装', '####### 七个井号', '#tag\n尾段']) {
      await tester.pumpWidget(_host(bad));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '输入「$bad」不应抛异常/卡死');
    }
    // 无空格标题退化为字面段落(内容仍在)。
    await tester.pumpWidget(_host('##安装'));
    await tester.pump();
    expect(find.textContaining('##安装'), findsWidgets);
  });

  // 回归:裸 ** / 空格包裹的 * 不该被吞成空斜体丢字符。
  testWidgets('裸星号退化为字面量不丢字符', (tester) async {
    await tester.pumpWidget(_host('see ** here 与 2 * 3 * 4'));
    await tester.pump();
    expect(find.textContaining('**'), findsWidgets); // ** 原样保留
    expect(find.textContaining('2 * 3 * 4'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  // 回归:带 | 的普通行紧接 --- 时,--- 不该被吞成幽灵表格(应渲染成分隔线)。
  testWidgets('--- 分隔线不被前一行的 | 吞掉', (tester) async {
    await tester.pumpWidget(_host('见下表 A|B 模式\n---\n尾段'));
    await tester.pump();
    expect(find.byType(Divider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 回归:正文来自远端(GitHub Release Note / 源脚本),链接的 scheme 不可信。
  // 以前直接 Uri.parse + launchUrl,等于把「打开任意深链」的口子交出去。
  group('外链只放行 http/https/mailto', () {
    test('放行的协议原样返回', () {
      expect(
        markdownLinkTarget('https://github.com/TypeDreamMoon'),
        Uri.parse('https://github.com/TypeDreamMoon'),
      );
      expect(markdownLinkTarget('http://example.com'), isNotNull);
      expect(markdownLinkTarget('mailto:a@b.c'), isNotNull);
      // 大小写与首尾空白不该绕过判断,也不该误伤。
      expect(markdownLinkTarget('  HTTPS://example.com  '), isNotNull);
    });

    test('其余协议一律拒绝', () {
      for (final bad in [
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'file:///C:/Windows/System32/drivers/etc/hosts',
        'intent://evil#Intent;scheme=http;end',
        'ms-settings:defaultapps',
        'data:text/html,<script>1</script>',
        'content://com.other.app/private',
      ]) {
        expect(markdownLinkTarget(bad), isNull, reason: bad);
      }
    });

    test('没有 scheme 的相对路径也拒绝', () {
      expect(markdownLinkTarget('docs/readme.md'), isNull);
      expect(markdownLinkTarget('//example.com'), isNull);
      expect(markdownLinkTarget(''), isNull);
    });
  });

  testWidgets('不放行的链接仍然渲染成文字,点了不会启动任何东西', (tester) async {
    await tester.pumpWidget(_host('点[这里](javascript:alert(1))试试'));
    await tester.pump();
    expect(find.textContaining('这里'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
