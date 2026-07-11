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
}
