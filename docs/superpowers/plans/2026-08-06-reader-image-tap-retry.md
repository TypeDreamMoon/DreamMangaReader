# Reader Image Tap Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让漫画阅读器中的单张网络图片加载失败后可点击失败占位重试，同时保持其他图片、章节状态和既有阅读手势不变。

**Architecture:** 新增一个只负责网络漫画页的 `RetryableReaderNetworkImage` 状态组件，将失败占位的点击处理、缓存驱逐和 attempt key 重建封装在同一处。`ReaderPage._image` 继续负责 Base64、本地文件和网络图片分流，仅把 HTTP 分支交给新组件，因此分页、双页、竖翻和长条模式自动共享同一行为。

**Tech Stack:** Flutter、Dart、`cached_network_image` 3.4.1、`flutter_cache_manager` 3.4.1、Flutter Widget Tests

---

## File Structure

- Create: `lib/features/reader/retryable_reader_network_image.dart`
  - 封装单张网络图片的加载、失败点击、缓存驱逐、并发保护和 attempt key。
- Modify: `lib/features/reader/reader_page.dart`
  - 保留 Base64 和本地文件分支，只将 HTTP 分支替换为新组件，并复用现有加载/破图视觉。
- Create: `test/retryable_reader_network_image_test.dart`
  - 使用内存缓存管理器稳定复现第一次解码失败、点击重试和第二次成功，并验证并发保护与参数保持。
- Modify: `pubspec.yaml`
  - 将测试直接使用的 `file` 包声明为 dev dependency。
- Modify: `pubspec.lock`
  - 记录 `file` 从 transitive 改为 direct dev dependency，不改变其锁定版本。

### Task 1: Lock Down Retry State And Cache Eviction

**Files:**
- Create: `test/retryable_reader_network_image_test.dart`
- Modify: `pubspec.yaml:92-96`
- Modify: `pubspec.lock:236-243`
- Create: `lib/features/reader/retryable_reader_network_image.dart`

- [ ] **Step 1: Declare the test-only in-memory filesystem dependency**

在 `dev_dependencies` 中加入与锁文件当前版本一致的直接依赖：

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  fake_async: 1.3.3
  file: 7.0.1
```

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter pub get
```

Expected: 命令成功；`pubspec.lock` 中 `file.dependency` 变为 `direct dev`，版本仍是 `7.0.1`。

- [ ] **Step 2: Write a failing widget test for one-image retry**

创建 `test/retryable_reader_network_image_test.dart`。测试辅助缓存管理器第一次返回损坏字节，`removeFile` 后返回有效的一像素 PNG；其余未使用接口通过 `noSuchMethod` 保持测试替身最小化：

```dart
import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_manga_reader/features/reader/retryable_reader_network_image.dart';

const _url = 'https://example.test/page.png';
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _RetryCacheManager implements BaseCacheManager {
  final _fileSystem = MemoryFileSystem();
  int loads = 0;
  int removes = 0;
  Completer<void>? removeBarrier;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    loads++;
    final bytes = loads == 1
        ? <int>[0, 1, 2, 3]
        : base64Decode(_onePixelPng);
    final file = _fileSystem.systemTempDirectory.childFile('page-$loads.png');
    await file.writeAsBytes(bytes);
    yield FileInfo(
      file,
      FileSource.Online,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<void> removeFile(String key) async {
    removes++;
    await removeBarrier?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(_RetryCacheManager cacheManager) => MaterialApp(
      home: Scaffold(
        body: RetryableReaderNetworkImage(
          imageUrl: _url,
          httpHeaders: const {'Referer': 'https://example.test/'},
          cacheManager: cacheManager,
          fit: BoxFit.contain,
          width: 320,
          height: 480,
          progressIndicatorBuilder: (_, __) =>
              const SizedBox(key: Key('reader-image-loading')),
          errorWidgetBuilder: (_, retrying) => SizedBox(
            key: Key(retrying
                ? 'reader-image-retrying'
                : 'reader-image-retry'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('tap evicts only the failed image and retries successfully',
      (tester) async {
    final cacheManager = _RetryCacheManager();
    await tester.pumpWidget(_host(cacheManager));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reader-image-retry')), findsOneWidget);
    expect(cacheManager.loads, 1);

    await tester.tap(find.byKey(const Key('reader-image-retry')));
    await tester.pumpAndSettle();

    expect(cacheManager.removes, 1);
    expect(cacheManager.loads, 2);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.byKey(const Key('reader-image-retry')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 3: Run the test to verify the component is missing**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test/retryable_reader_network_image_test.dart
```

Expected: FAIL because `retryable_reader_network_image.dart` / `RetryableReaderNetworkImage` does not exist.

- [ ] **Step 4: Implement the minimal retryable network image component**

创建 `lib/features/reader/retryable_reader_network_image.dart`：

```dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

typedef ReaderImageProgressBuilder = Widget Function(
  BuildContext context,
  DownloadProgress progress,
);

typedef ReaderImageErrorBuilder = Widget Function(
  BuildContext context,
  bool retrying,
);

class RetryableReaderNetworkImage extends StatefulWidget {
  const RetryableReaderNetworkImage({
    super.key,
    required this.imageUrl,
    required this.httpHeaders,
    required this.cacheManager,
    required this.fit,
    required this.progressIndicatorBuilder,
    required this.errorWidgetBuilder,
    this.width,
    this.height,
  });

  final String imageUrl;
  final Map<String, String> httpHeaders;
  final BaseCacheManager cacheManager;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ReaderImageProgressBuilder progressIndicatorBuilder;
  final ReaderImageErrorBuilder errorWidgetBuilder;

  @override
  State<RetryableReaderNetworkImage> createState() =>
      _RetryableReaderNetworkImageState();
}

class _RetryableReaderNetworkImageState
    extends State<RetryableReaderNetworkImage> {
  int _attempt = 0;
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await CachedNetworkImage.evictFromCache(
        widget.imageUrl,
        cacheManager: widget.cacheManager,
      );
    } catch (_) {
      // 即使缓存驱逐失败，也要更换 attempt key 重新请求。
    }
    if (!mounted) return;
    setState(() {
      _retrying = false;
      _attempt++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      key: ValueKey('${widget.imageUrl}#$_attempt'),
      cacheManager: widget.cacheManager,
      imageUrl: widget.imageUrl,
      httpHeaders: widget.httpHeaders,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      fadeInDuration: const Duration(milliseconds: 120),
      progressIndicatorBuilder: (_, __, progress) =>
          widget.progressIndicatorBuilder(context, progress),
      errorWidget: (_, __, ___) => GestureDetector(
        key: const Key('reader-network-image-retry-target'),
        behavior: HitTestBehavior.opaque,
        onTap: _retrying ? null : _retry,
        child: widget.errorWidgetBuilder(context, _retrying),
      ),
    );
  }
}
```

- [ ] **Step 5: Run the focused test to verify the retry path passes**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test/retryable_reader_network_image_test.dart
```

Expected: PASS; first decode shows the retry target, one tap calls `removeFile` once, then the valid image renders.

- [ ] **Step 6: Commit the retry component and first test**

```powershell
$ErrorActionPreference = 'Stop'
git add pubspec.yaml pubspec.lock lib/features/reader/retryable_reader_network_image.dart test/retryable_reader_network_image_test.dart
git commit -m "feat(reader): retry failed network images"
```

### Task 2: Prevent Concurrent Retries And Preserve Request Parameters

**Files:**
- Modify: `test/retryable_reader_network_image_test.dart`
- Modify: `lib/features/reader/retryable_reader_network_image.dart`

- [ ] **Step 1: Add a failing concurrency and parameter-preservation test**

扩展 `_RetryCacheManager`，记录每次加载的 headers：

```dart
final loadHeaders = <Map<String, String>?>[];

// 放在 getFileStream 开头：
loadHeaders.add(headers == null ? null : Map.of(headers));
```

加入测试；缓存删除被 `Completer` 阻塞时，第二次点击不得开始新的删除或加载：

```dart
testWidgets('retry ignores repeated taps and preserves image parameters',
    (tester) async {
  final cacheManager = _RetryCacheManager();
  await tester.pumpWidget(_host(cacheManager));
  await tester.pumpAndSettle();

  cacheManager.removeBarrier = Completer<void>();
  await tester.tap(find.byKey(const Key('reader-image-retry')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('reader-image-retrying')));
  await tester.pump();

  expect(cacheManager.removes, 1);
  expect(cacheManager.loads, 1);

  cacheManager.removeBarrier!.complete();
  await tester.pumpAndSettle();

  expect(cacheManager.loads, 2);
  expect(cacheManager.loadHeaders, const [
    {'Referer': 'https://example.test/'},
    {'Referer': 'https://example.test/'},
  ]);
  final image = tester.widget<CachedNetworkImage>(
    find.byType(CachedNetworkImage),
  );
  expect(image.fit, BoxFit.contain);
  expect(image.width, 320);
  expect(image.height, 480);
});
```

- [ ] **Step 2: Run the focused test and confirm it exposes any hit-target gap**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test/retryable_reader_network_image_test.dart
```

Expected: 新测试若无法在 `_retrying` 状态继续命中失败区域则 FAIL；已有单次重试测试仍 PASS。

- [ ] **Step 3: Keep the failed area present and disabled while eviction runs**

确保 `_retry` 第一帧的 `setState` 只更新失败区域内容和 `onTap`，不替换 `CachedNetworkImage` 的 attempt key；只有缓存驱逐完成后才执行 `_attempt++`。`errorWidget` 保持如下逻辑：

```dart
errorWidget: (_, __, ___) => GestureDetector(
  key: const Key('reader-network-image-retry-target'),
  behavior: HitTestBehavior.opaque,
  onTap: _retrying ? null : _retry,
  child: widget.errorWidgetBuilder(context, _retrying),
),
```

这让连续点击落在同一失败区域，但 `_retrying` 状态会拒绝并发重试。

- [ ] **Step 4: Run both component tests**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test/retryable_reader_network_image_test.dart
```

Expected: 2 tests PASS；删除次数为 1，第二次加载保留 URL、headers、fit、width 和 height。

- [ ] **Step 5: Commit concurrency coverage**

```powershell
$ErrorActionPreference = 'Stop'
git add lib/features/reader/retryable_reader_network_image.dart test/retryable_reader_network_image_test.dart
git commit -m "test(reader): cover repeated image retry taps"
```

### Task 3: Integrate The Shared HTTP Branch Into ReaderPage

**Files:**
- Modify: `lib/features/reader/reader_page.dart:14-24,1105-1147`
- Modify: `test/reader_base64_page_test.dart`

- [ ] **Step 1: Add a failing reader integration assertion**

在 `test/reader_base64_page_test.dart` 导入新组件，并加入一个不等待真实网络的结构性回归测试。将 `_FakeSource` 的 HTTP 页交给阅读器后，首次 `pump` 应建立新的网络组件；Base64 和本地页仍不得建立它：

```dart
import 'package:dream_manga_reader/features/reader/retryable_reader_network_image.dart';

testWidgets('only HTTP pages use the retryable network image', (tester) async {
  SharedPreferences.setMockInitialValues({});
  final store = LibraryStore();
  await store.load();

  await tester.pumpWidget(
    harness(store, const [
      PageImage(index: 0, url: 'https://example.test/page.png'),
    ]),
  );
  await tester.pump();

  expect(find.byType(RetryableReaderNetworkImage), findsOneWidget);
  store.dispose();
});
```

同时在现有 Base64 和本地文件测试中加入：

```dart
expect(find.byType(RetryableReaderNetworkImage), findsNothing);
```

- [ ] **Step 2: Run the integration tests to verify the HTTP branch still uses CachedNetworkImage directly**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test/reader_base64_page_test.dart
```

Expected: 新 HTTP 断言 FAIL；现有 Base64 和本地文件回归继续 PASS。

- [ ] **Step 3: Replace only ReaderPage's HTTP rendering branch**

在 `reader_page.dart` 增加导入：

```dart
import 'retryable_reader_network_image.dart';
```

保持 `_image` 的 Base64 与本地文件分支原样，将最后的网络返回值替换为：

```dart
return RetryableReaderNetworkImage(
  imageUrl: img.url,
  httpHeaders: _headers(img),
  cacheManager: appImageCache,
  fit: fit,
  width: w,
  height: height,
  progressIndicatorBuilder: (_, progress) => _loading(progress, fullWidth),
  errorWidgetBuilder: (context, retrying) => _retryableBroken(
    fullWidth,
    retrying: retrying,
  ),
);
```

保留现有 `_broken` 不变，供 Base64 和本地文件的静态失败占位使用。新增 `_retryableBroken`，保留原图标并使用现有本地化 `retry` 文案；重试进行中显示小型进度环，避免用户误以为点击无效：

```dart
Widget _retryableBroken(bool fullWidth, {bool retrying = false}) => Container(
      height: fullWidth ? 200 : null,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (retrying)
            const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(
              Icons.broken_image_rounded,
              color: Colors.white38,
              size: 40,
            ),
          const SizedBox(height: 8),
          Text(
            context.l10n.retry,
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
```

Base64 和本地文件的 `errorBuilder` 继续调用原有 `_broken(fullWidth)`，只显示破图图标，不显示“重试”文案，也没有 `GestureDetector`。

- [ ] **Step 4: Run focused reader tests**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test/retryable_reader_network_image_test.dart test/reader_base64_page_test.dart test/page_image_data_test.dart
```

Expected: 全部 PASS；HTTP 页使用重试组件，Base64 仍使用 `MemoryImage`，本地页仍使用 `FileImage`。

- [ ] **Step 5: Format and run focused static analysis**

Run:

```powershell
$ErrorActionPreference = 'Stop'
dart format lib/features/reader/retryable_reader_network_image.dart lib/features/reader/reader_page.dart test/retryable_reader_network_image_test.dart test/reader_base64_page_test.dart
dart analyze lib/features/reader/retryable_reader_network_image.dart lib/features/reader/reader_page.dart test/retryable_reader_network_image_test.dart test/reader_base64_page_test.dart
git diff --check
```

Expected: formatter completes, analyzer reports no issues, and `git diff --check` has no output.

- [ ] **Step 6: Commit the ReaderPage integration**

```powershell
$ErrorActionPreference = 'Stop'
git add lib/features/reader/reader_page.dart test/reader_base64_page_test.dart
git commit -m "feat(reader): expose tap retry for failed pages"
```

### Task 4: Final Regression And Scope Check

**Files:**
- Verify only; no planned production changes

- [ ] **Step 1: Run the bounded regression suite**

Run:

```powershell
$ErrorActionPreference = 'Stop'
flutter test test/retryable_reader_network_image_test.dart test/reader_base64_page_test.dart test/page_image_data_test.dart test/widget_test.dart
```

Expected: 全部 PASS。不要运行 Windows/Android 构建、打包或真机测试。

- [ ] **Step 2: Verify the final diff stays inside the approved scope**

Run:

```powershell
$ErrorActionPreference = 'Stop'
git status --short
git diff upstream/main...HEAD -- lib/features/reader/retryable_reader_network_image.dart lib/features/reader/reader_page.dart test/retryable_reader_network_image_test.dart test/reader_base64_page_test.dart pubspec.yaml pubspec.lock
git diff --check
```

Expected: 当前功能只涉及计划列出的组件、阅读器接入、测试和测试依赖；没有源脚本、下载、阅读进度或平台工程变更。

- [ ] **Step 3: Record verification without pushing**

```powershell
$ErrorActionPreference = 'Stop'
git status --short --branch
git log -4 --oneline
```

Expected: 本地分支包含本计划的独立提交；不执行 `git push`，不创建或更新远端 PR。
