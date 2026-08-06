# Anime Seek And Ad Discontinuity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复番剧拖动卡顿、seek 后回到开头，以及广告或编码边界后播放失败和持续爆音的问题。

**Architecture:** `PlaybackSessionController` 成为唯一 seek 状态所有者，页面使用应用自有控制条，所有拖动都经过 controller 和 adapter。HLS 网关采用边下载边回传、成功后再原子提交缓存，并用保序 token 重写媒体清单；仅移除明确标记的 VOD 广告区间，遇到解码边界错误时清理外置音频状态并从权威位置重开。

**Tech Stack:** Flutter、Dart、media_kit、Dio、dart:io HTTP server、Flutter unit/widget/integration tests

---

## File Structure

- Modify: `lib/features/anime/playback/playback_state.dart`
  - 暴露已确认位置、待确认 seek 目标和 seek 中状态。
- Modify: `lib/features/anime/playback/playback_session_controller.dart`
  - 实现可靠 seek 状态机、权威恢复位置和瞬时零位置过滤。
- Modify: `lib/features/anime/playback/player_adapter.dart`
  - 保持单一 seek 入口，并增加解码边界重建契约。
- Create: `lib/features/anime/anime_player_controls.dart`
  - 提供播放/暂停、进度预览、短跳转、时间和面板入口。
- Modify: `lib/features/anime/anime_player_page.dart`
  - 用应用控制条包裹原生视频画面，停止使用 media_kit 默认 seek 控件。
- Modify: `lib/features/anime/playback/hls_session.dart`
  - 让 seek 代际和下一媒体请求优先级显式化。
- Modify: `lib/features/anime/playback/hls_cache_store.dart`
  - 分离临时下载、原子提交和完整缓存租约。
- Create: `lib/features/anime/playback/hls_stream_response.dart`
  - 表达上游流式响应、Range 元数据和取消生命周期。
- Modify: `lib/features/anime/playback/hls_cache_gateway.dart`
  - 流式转发 cache miss、实现 Range/206、接入保序清单重写。
- Create: `lib/features/anime/playback/hls_media_rewriter.dart`
  - 无损重写媒体清单 URI，并保守识别明确广告标记。
- Modify: `lib/features/anime/playback/media_kit_player_adapter.dart`
  - seek 通知、解码器重建和外置音频状态清理。
- Modify: `test/playback_session_controller_test.dart`
- Create: `test/anime_player_controls_test.dart`
- Modify: `test/anime_player_page_test.dart`
- Modify: `test/media_kit_player_adapter_test.dart`
- Create: `test/hls_media_rewriter_test.dart`
- Modify: `test/hls_cache_gateway_test.dart`
- Modify: `test/hls_cache_store_test.dart`
- Modify: `test/anime_playback_integration_test.dart`

### Task 1: Make Seek Targets Authoritative

**Files:**
- Modify: `lib/features/anime/playback/playback_state.dart`
- Modify: `lib/features/anime/playback/playback_session_controller.dart`
- Test: `test/playback_session_controller_test.dart`

- [ ] **Step 1: Write failing controller tests**

在 `test/playback_session_controller_test.dart` 增加以下场景，复用现有 `_FakePlayerAdapter`，并让它记录 `pause`、`play` 和 `seek` 调用：

```dart
test('pending seek ignores transient zero and recovery uses the target',
    () async {
  final adapter = _FakePlayerAdapter();
  final controller = PlaybackSessionController(
    player: adapter,
    tracks: _FakeTrackProvider(),
    delay: (_) async {},
  );
  await controller.start(const [_track480], _track480);
  adapter.playingController.add(true);
  adapter.positionController.add(const Duration(seconds: 40));

  await controller.seekTo(
    const Duration(minutes: 8),
    resumeAfterSeek: true,
  );
  adapter.positionController.add(Duration.zero);
  adapter.errorController.add(StateError('decoder boundary'));
  await Future<void>.delayed(Duration.zero);

  expect(controller.state.pendingSeekTarget, const Duration(minutes: 8));
  expect(adapter.seeks.last, const Duration(minutes: 8));
  expect(controller.state.position, isNot(Duration.zero));
});

test('newer seek supersedes an older seek and a paused user stays paused',
    () async {
  final adapter = _FakePlayerAdapter();
  final controller = PlaybackSessionController(
    player: adapter,
    tracks: _FakeTrackProvider(),
  );
  await controller.start(const [_track480], _track480);

  final first = controller.seekTo(
    const Duration(minutes: 3),
    resumeAfterSeek: false,
  );
  final second = controller.seekTo(
    const Duration(minutes: 7),
    resumeAfterSeek: false,
  );
  await Future.wait([first, second]);
  adapter.positionController.add(const Duration(minutes: 7, seconds: 1));

  expect(adapter.seeks, endsWith([const Duration(minutes: 3), const Duration(minutes: 7)]));
  expect(controller.state.pendingSeekTarget, isNull);
  expect(adapter.playCalls, 0);
});
```

- [ ] **Step 2: Run the controller tests and verify RED**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\playback_session_controller_test.dart'
```

Expected: FAIL because `seekTo` and `pendingSeekTarget` do not exist and zero positions are currently accepted.

- [ ] **Step 3: Add explicit seek state**

在 `PlaybackState` 增加字段和 copy 参数：

```dart
final Duration? pendingSeekTarget;
final bool seeking;

PlaybackState copyWith({
  Duration? position,
  Duration? pendingSeekTarget,
  bool clearPendingSeekTarget = false,
  bool? seeking,
  // existing parameters stay unchanged
}) => PlaybackState(
  position: position ?? this.position,
  pendingSeekTarget: clearPendingSeekTarget
      ? null
      : pendingSeekTarget ?? this.pendingSeekTarget,
  seeking: seeking ?? this.seeking,
  // copy existing fields
);
```

构造函数默认 `pendingSeekTarget = null`、`seeking = false`。

- [ ] **Step 4: Implement the controller seek state machine**

用 `_confirmedPosition` 替代 `_position`，并增加：

```dart
Duration _confirmedPosition = Duration.zero;
Duration? _pendingSeekTarget;
int _seekGeneration = 0;
bool _resumeAfterSeek = false;

Duration get _recoveryPosition =>
    _pendingSeekTarget ?? _confirmedPosition;

Future<void> seekTo(
  Duration target, {
  required bool resumeAfterSeek,
}) async {
  if (_disposed || _selected == null) return;
  final bounded = target < Duration.zero
      ? Duration.zero
      : (_duration > Duration.zero && target > _duration ? _duration : target);
  final seekGeneration = ++_seekGeneration;
  _pendingSeekTarget = bounded;
  _resumeAfterSeek = resumeAfterSeek;
  _stallTimer?.cancel();
  await _player.pause();
  if (_disposed || seekGeneration != _seekGeneration) return;
  _emit(_state.copyWith(
    position: bounded,
    pendingSeekTarget: bounded,
    seeking: true,
  ));
  await _player.seek(bounded);
}
```

`_onPosition` 在 pending 状态只接受与目标相差不超过 3 秒，或已经越过目标但不超过 10 秒的位置；拒绝瞬时 0 和明显倒退。确认后清空 pending，并仅在 `_resumeAfterSeek` 为 true 时调用 `_player.play()`。`_open`、`_recover` 和线路切换的 resume seek 均读取 `_recoveryPosition`，不得把显式 seek 交给 near-end 归零逻辑。

- [ ] **Step 5: Run controller tests and verify GREEN**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; dart format lib\features\anime\playback\playback_state.dart lib\features\anime\playback\playback_session_controller.dart test\playback_session_controller_test.dart; flutter test test\playback_session_controller_test.dart'
```

Expected: all controller tests PASS, including existing initial resume, stall recovery and pause persistence tests.

- [ ] **Step 6: Commit reliable seek state**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add lib\features\anime\playback\playback_state.dart lib\features\anime\playback\playback_session_controller.dart test\playback_session_controller_test.dart; git commit -m ''fix(anime): keep seek targets authoritative'''
```

### Task 2: Replace Default Seek Controls

**Files:**
- Create: `lib/features/anime/anime_player_controls.dart`
- Modify: `lib/features/anime/anime_player_page.dart`
- Create: `test/anime_player_controls_test.dart`
- Modify: `test/anime_player_page_test.dart`

- [ ] **Step 1: Write failing widget tests for drag and pause semantics**

创建 `test/anime_player_controls_test.dart`：

```dart
testWidgets('drag previews target then commits one paused seek', (tester) async {
  Duration? committed;
  bool? resumeAfterSeek;
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: AnimePlayerControls(
    position: const Duration(minutes: 2),
    duration: const Duration(minutes: 10),
    playing: true,
    buffering: false,
    onPlayPause: () {},
    onSeek: (target, resume) {
      committed = target;
      resumeAfterSeek = resume;
    },
    onOpenPanel: () {},
  ))));

  await tester.drag(find.byType(Slider), const Offset(240, 0));
  await tester.pump();

  expect(committed, isNotNull);
  expect(committed!, greaterThan(const Duration(minutes: 2)));
  expect(resumeAfterSeek, isTrue);
});
```

在 `anime_player_page_test.dart` 增加断言：页面存在 `AnimePlayerControls`，拖动时只调用 fake adapter 经 controller 暴露的 `seek`，且页面源码不再创建带默认 controls 的 `Video`。

- [ ] **Step 2: Run widget tests and verify RED**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\anime_player_controls_test.dart test\anime_player_page_test.dart'
```

Expected: FAIL because `AnimePlayerControls` does not exist and the page still uses media_kit controls.

- [ ] **Step 3: Create stable application controls**

实现公开构造器：

```dart
class AnimePlayerControls extends StatefulWidget {
  const AnimePlayerControls({
    super.key,
    required this.position,
    required this.duration,
    required this.playing,
    required this.buffering,
    required this.onPlayPause,
    required this.onSeek,
    required this.onOpenPanel,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final VoidCallback onPlayPause;
  final void Function(Duration target, bool resumeAfterSeek) onSeek;
  final VoidCallback onOpenPanel;
}
```

内部用 `Slider` 的 `onChangeStart` 保存 `widget.playing`，`onChanged` 仅更新 `_preview`，`onChangeEnd` 只调用一次 `onSeek(target, _wasPlaying)`。左右短跳转按钮分别 clamp 到 `0` 和 `duration`；所有图标按钮提供 tooltip，控件高度固定，时间使用 `mm:ss` 或 `hh:mm:ss`。

- [ ] **Step 4: Wire controls through PlaybackSessionController**

原生画面改为禁用默认 controls：

```dart
videoBuilder: (fit) => Video(
  controller: videoController,
  fit: fit,
  controls: NoVideoControls,
),
```

在视频画面上用 `Stack` 放置 `AnimePlayerControls`，回调必须是：

```dart
onPlayPause: () {
  final playing = _playback.phase == PlaybackPhase.playing;
  _session?.setUserPaused(playing);
  if (!playing) unawaited(_adapter?.play());
},
onSeek: (target, resume) =>
    unawaited(_session?.seekTo(target, resumeAfterSeek: resume)),
onOpenPanel: () => _scaffoldKey.currentState?.openEndDrawer(),
```

不直接调用 `NativeMediaKitBackend.seek`、`Player.seek` 或 `videoController.player.seek`。

- [ ] **Step 5: Run widget tests and verify GREEN**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; dart format lib\features\anime\anime_player_controls.dart lib\features\anime\anime_player_page.dart test\anime_player_controls_test.dart test\anime_player_page_test.dart; flutter test test\anime_player_controls_test.dart test\anime_player_page_test.dart'
```

Expected: all selected widget tests PASS; drag commits one controller seek and preserves pre-drag play/pause intent.

- [ ] **Step 6: Commit application controls**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add lib\features\anime\anime_player_controls.dart lib\features\anime\anime_player_page.dart test\anime_player_controls_test.dart test\anime_player_page_test.dart; git commit -m ''feat(anime): route playback controls through session'''
```

### Task 3: Stream Cache Misses And Honor Range

**Files:**
- Create: `lib/features/anime/playback/hls_stream_response.dart`
- Modify: `lib/features/anime/playback/hls_session.dart`
- Modify: `lib/features/anime/playback/hls_cache_store.dart`
- Modify: `lib/features/anime/playback/hls_cache_gateway.dart`
- Modify: `lib/features/anime/playback/media_kit_player_adapter.dart`
- Test: `test/hls_cache_store_test.dart`
- Test: `test/hls_cache_gateway_test.dart`
- Test: `test/media_kit_player_adapter_test.dart`

- [ ] **Step 1: Write failing stream-through, cancellation, Range and seek-priority tests**

扩展 `FaultHttpServer` 支持分块 gate 后，在 `hls_cache_gateway_test.dart` 增加：

```dart
test('serves first miss bytes before cache commit and commits on completion',
    () async {
  final releaseTail = Completer<void>();
  upstream.addChunked('/slow.ts', [[1, 2], [3, 4]], beforeChunk: (index) async {
    if (index == 1) await releaseTail.future;
  });
  final segment = await _openSingleSegment(gateway, upstream, 'slow.ts');
  final client = HttpClient();
  final response = await (await client.getUrl(segment)).close();
  final firstChunk = Completer<List<int>>();
  final all = <int>[];
  final done = Completer<void>();
  response.listen((chunk) {
    all.addAll(chunk);
    if (!firstChunk.isCompleted) firstChunk.complete(List.of(chunk));
  }, onDone: done.complete, onError: done.completeError);
  expect(await firstChunk.future, [1, 2]);
  expect(await temp.list().where((e) => e.path.endsWith('.bin')).isEmpty, isTrue);
  releaseTail.complete();
  await done.future;
  expect(all, [1, 2, 3, 4]);
});

test('completed cache and upstream misses honor byte ranges', () async {
  final segment = await _openBytes(gateway, upstream, List.generate(10, (i) => i));
  expect((await _get(segment)).bytes, List.generate(10, (i) => i));
  final ranged = await _get(segment, headers: const {'Range': 'bytes=3-6'});
  expect(ranged.status, HttpStatus.partialContent);
  expect(ranged.bytes, [3, 4, 5, 6]);
});
```

在 store 测试中断流后断言 `.tmp` 被删除且不存在 `.bin`；在 adapter 测试调用 `seek` 后断言 fake session 的 `notifySeek` 次数递增。

- [ ] **Step 2: Run cache and adapter tests and verify RED**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\hls_cache_store_test.dart test\hls_cache_gateway_test.dart test\media_kit_player_adapter_test.dart'
```

Expected: FAIL because upstream responses are buffered as `List<int>`, cache commit blocks first bytes, and local Range always returns 200.

- [ ] **Step 3: Introduce a streaming upstream response**

创建：

```dart
class HlsStreamResponse {
  const HlsStreamResponse({
    required this.statusCode,
    required this.stream,
    required this.headers,
    required this.cancel,
  });
  final int statusCode;
  final Stream<List<int>> stream;
  final Map<String, List<String>> headers;
  final Future<void> Function() cancel;
  String get contentType =>
      headers[HttpHeaders.contentTypeHeader]?.firstOrNull ??
      'application/octet-stream';
  int? get contentLength => int.tryParse(
      headers[HttpHeaders.contentLengthHeader]?.firstOrNull ?? '');
}
```

把 `HlsUpstreamClient.get` 返回值改为 `Future<HlsStreamResponse>`。Dio 使用 `ResponseType.stream`，从 `ResponseBody.stream` 转发 chunk，Range 请求设置 `Range: bytes=start-end`，取消函数关闭订阅/响应。

- [ ] **Step 4: Separate cache lookup, temporary write and atomic commit**

在 `HlsCacheStore` 增加：

```dart
Future<HlsCacheLease?> lookup(HlsCacheRequest request);
Future<HlsCacheWriter> beginWrite(HlsCacheRequest request);

abstract interface class HlsCacheWriter {
  IOSink get sink;
  Future<HlsCacheLease> commit({
    required String contentType,
    required int? expectedLength,
  });
  Future<void> abort();
}
```

`commit` 必须 flush/close sink、校验长度、在同目录 rename `.tmp` 为 `.bin`、更新 index 后才返回 lease；`abort` 关闭 sink 并删除 `.tmp`。Range miss 不调用 `commit`，避免局部字节冒充完整缓存。

- [ ] **Step 5: Stream media responses with backpressure and 206 metadata**

`_serveMedia` 先 `lookup` 完整缓存。命中时解析单一 `Range`，设置 `206`、`Content-Range`、`Accept-Ranges: bytes` 和准确 `Content-Length`，再用 `file.openRead(start, endExclusive)` 回传。未命中时将客户端 Range 传上游；完整 200 响应用 `await for (final chunk in upstream.stream)` 同时 `response.add(chunk)` 和 `writer.sink.add(chunk)`，成功后 commit，捕获错误或客户端取消时执行 `abort` 和 `upstream.cancel()`。

`HlsSession.notifySeek` 增加 generation、取消现有 prefetch，并设置 `prioritizeNextMedia = true`；下一次播放器媒体请求先清除该标志并独占前台请求，不等待旧 prefetch。

- [ ] **Step 6: Run stream, Range and existing cache tests**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; dart format lib\features\anime\playback\hls_stream_response.dart lib\features\anime\playback\hls_session.dart lib\features\anime\playback\hls_cache_store.dart lib\features\anime\playback\hls_cache_gateway.dart lib\features\anime\playback\media_kit_player_adapter.dart test\hls_cache_store_test.dart test\hls_cache_gateway_test.dart test\media_kit_player_adapter_test.dart; flutter test test\hls_cache_store_test.dart test\hls_cache_gateway_test.dart test\media_kit_player_adapter_test.dart'
```

Expected: all selected tests PASS; first bytes arrive before `.bin` exists, cancellation leaves no hit, and valid Range returns 206 with exact bytes.

- [ ] **Step 7: Commit streaming and Range support**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add lib\features\anime\playback\hls_stream_response.dart lib\features\anime\playback\hls_session.dart lib\features\anime\playback\hls_cache_store.dart lib\features\anime\playback\hls_cache_gateway.dart lib\features\anime\playback\media_kit_player_adapter.dart test\hls_cache_store_test.dart test\hls_cache_gateway_test.dart test\media_kit_player_adapter_test.dart; git commit -m ''feat(anime): stream HLS cache misses and ranges'''
```

### Task 4: Rewrite Media Playlists Losslessly And Filter Explicit Ads

**Files:**
- Create: `lib/features/anime/playback/hls_media_rewriter.dart`
- Modify: `lib/features/anime/playback/hls_cache_gateway.dart`
- Create: `test/hls_media_rewriter_test.dart`
- Modify: `test/hls_cache_gateway_test.dart`

- [ ] **Step 1: Write failing lossless-rewrite and conservative-ad tests**

```dart
test('preserves ordered maps keys ranges discontinuities and unknown tags', () {
  const input = '''#EXTM3U
#EXT-X-MAP:URI="init-a.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="a.key"
#EXT-X-VENDOR-CUSTOM:keep-me
#EXTINF:4,
a.m4s
#EXT-X-DISCONTINUITY
#EXT-X-MAP:URI="init-b.mp4"
#EXT-X-BYTERANGE:10@20
#EXTINF:4,
b.m4s
#EXT-X-ENDLIST
''';
  final output = HlsMediaRewriter().rewrite(
    input,
    baseUri: Uri.parse('https://example.test/v/'),
    register: (uri, kind, range) => Uri.parse('http://127.0.0.1/${uri.pathSegments.last}'),
  );
  expect(output.text.indexOf('init-a.mp4'), lessThan(output.text.indexOf('a.m4s')));
  expect(output.text.indexOf('init-b.mp4'), greaterThan(output.text.indexOf('#EXT-X-DISCONTINUITY')));
  expect(output.text, contains('#EXT-X-VENDOR-CUSTOM:keep-me'));
  expect(output.text, contains('#EXT-X-BYTERANGE:10@20'));
});

test('removes only explicitly marked VOD ads', () {
  final cue = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:4,
content-a.ts
#EXT-X-CUE-OUT:8
#EXTINF:4,
ad-a.ts
#EXTINF:4,
ad-b.ts
#EXT-X-CUE-IN
#EXTINF:4,
content-b.ts
#EXT-X-ENDLIST
''');
  expect(cue, contains('content-a.ts'));
  expect(cue, isNot(contains('ad-a.ts')));
  expect(cue, isNot(contains('ad-b.ts')));
  expect(cue, contains('#EXT-X-DISCONTINUITY'));

  final ambiguous = rewrite('''#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-DISCONTINUITY
#EXT-X-DATERANGE:ID="chapter"
#EXTINF:4,
keep.ts
#EXT-X-ENDLIST
''');
  expect(ambiguous, contains('keep.ts'));
});
```

另加直播清单带 `CUE-OUT/IN` 仍保留全部 segment，以及多个 `EXT-X-MAP` 最终通过 gateway 注册到不同本地 URI 的测试。

- [ ] **Step 2: Run rewriter tests and verify RED**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\hls_media_rewriter_test.dart test\hls_cache_gateway_test.dart'
```

Expected: FAIL because the rewriter does not exist and structured `HlsMediaPlaylist` composition collapses multiple maps.

- [ ] **Step 3: Implement an ordered token rewriter**

定义接口：

```dart
enum HlsUriKind { segment, init, key }
typedef HlsUriRegistrar = Uri Function(
  Uri upstream,
  HlsUriKind kind,
  HlsByteRange? range,
);

class HlsRewriteResult {
  const HlsRewriteResult({required this.text, required this.duration});
  final String text;
  final Duration duration;
}
```

逐行扫描并保留原始顺序。只改写 segment URI 行以及 `EXT-X-MAP`、`EXT-X-KEY` 的 `URI` 属性；属性解析必须识别引号内逗号，不能用 `split(',')`。`EXT-X-BYTERANGE` 绑定下一 segment，MAP 自身 BYTERANGE 绑定该 MAP。未知标签原样输出。

- [ ] **Step 4: Add explicit VOD ad state**

仅在存在 `EXT-X-ENDLIST` 或 `PLAYLIST-TYPE:VOD` 时启用过滤。状态机接受 `EXT-X-CUE-OUT/IN`、`EXT-X-SCTE35-OUT/IN`，以及 `EXT-X-DATERANGE` 中 `CLASS` 明确包含 `ad`/`advert`/`interstitial` 或具有 `SCTE35-OUT/IN` 属性的区间。配对无效时返回原清单且不删 segment。删除区间后在内容两侧保留一个 `EXT-X-DISCONTINUITY`，并把结果 duration 设为保留 `EXTINF` 总和；裸 discontinuity 和含糊 daterange 不触发过滤。

- [ ] **Step 5: Integrate the rewriter in the gateway**

master playlist 继续使用当前结构化解析；识别为 media playlist 后改用 `HlsMediaRewriter.rewrite`。registrar 将 segment、init、key 分别映射成 `_ResourceKind.segment/init/key`，并携带 byte range。gateway 不再从 `HlsMediaPlaylist.initSegment` 推断全局 MAP。

- [ ] **Step 6: Run rewriter and gateway tests**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; dart format lib\features\anime\playback\hls_media_rewriter.dart lib\features\anime\playback\hls_cache_gateway.dart test\hls_media_rewriter_test.dart test\hls_cache_gateway_test.dart; flutter test test\hls_media_rewriter_test.dart test\hls_cache_gateway_test.dart'
```

Expected: all selected tests PASS; tag order and unknown tags are unchanged, explicit VOD ads alone are removed, and live/ambiguous content remains intact.

- [ ] **Step 7: Commit playlist and ad handling**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add lib\features\anime\playback\hls_media_rewriter.dart lib\features\anime\playback\hls_cache_gateway.dart test\hls_media_rewriter_test.dart test\hls_cache_gateway_test.dart; git commit -m ''fix(anime): preserve HLS boundaries and explicit ads'''
```

### Task 5: Reset Decoder And Audio State At Boundaries

**Files:**
- Modify: `lib/features/anime/playback/player_adapter.dart`
- Modify: `lib/features/anime/playback/media_kit_player_adapter.dart`
- Modify: `lib/features/anime/playback/playback_session_controller.dart`
- Modify: `test/media_kit_player_adapter_test.dart`
- Modify: `test/playback_session_controller_test.dart`
- Modify: `test/anime_player_page_test.dart`
- Modify: `test/anime_playback_integration_test.dart`

- [ ] **Step 1: Write failing decoder-boundary recovery tests**

```dart
test('boundary recovery clears stale audio before reopening at target',
    () async {
  const dash = VideoTrack(
    url: 'https://media.test/video.m4s',
    audioUrl: 'https://media.test/audio.m4s',
  );
  final backend = _FakeBackend()..mediaDuration = const Duration(minutes: 20);
  final adapter = MediaKitPlayerAdapter(
    backend: backend,
    gateway: _FakeGateway(),
    authScope: 'source:test',
  );
  await adapter.open(dash);
  backend.playingController.add(true);
  await Future<void>.delayed(Duration.zero);
  await adapter.rebuildDecoder(const Duration(minutes: 9));

  expect(backend.clearedAudioCount, 1);
  expect(backend.opened.last, dash);
  expect(backend.seeks.last, const Duration(minutes: 9));
  expect(backend.attachedAudio, [dash.audioUrl]);
});
```

集成测试构造显式广告区间和两个 MAP，跨边界触发 backend error 后断言重开位置为 pending/confirmed 非零位置，历史回调未收到 `Duration.zero`。

- [ ] **Step 2: Run boundary tests and verify RED**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\media_kit_player_adapter_test.dart test\playback_session_controller_test.dart test\anime_playback_integration_test.dart'
```

Expected: FAIL because backend/adapter have no `clearAudio` or `rebuildDecoder`, and stale audio attachment state survives fallback.

- [ ] **Step 3: Add the decoder rebuild contract**

在 `PlayerAdapter` 增加：

```dart
Future<void> rebuildDecoder(Duration resumePosition);
```

在 `MediaKitBackend` 增加：

```dart
Future<void> clearAudio();
```

`NativeMediaKitBackend.clearAudio` 调用 `player.setAudioTrack(AudioTrack.auto())` 解除旧外置 URI。`playback_session_controller_test.dart` 和 `anime_player_page_test.dart` 的 `PlayerAdapter` fake 实现 `rebuildDecoder`；`media_kit_player_adapter_test.dart` 和 `anime_playback_integration_test.dart` 的 backend fake 实现 `clearAudio`，不使用动态调用。

- [ ] **Step 4: Clear attachment state before every decoder reopen**

```dart
Future<void> _resetAudioAttachment() async {
  _audioTimer?.cancel();
  _audioTimer = null;
  _audioAttached = false;
  await _backend.clearAudio();
}

@override
Future<void> rebuildDecoder(Duration resumePosition) async {
  final track = _originalTrack;
  if (track == null || _disposed) return;
  await _resetAudioAttachment();
  await _closeSession();
  await open(track);
  if (resumePosition > Duration.zero) await seek(resumePosition);
}
```

避免 `open` 重复覆盖 `_pendingAudioUrl` 前未清理旧 timer。`_openDirectFallback` 也必须先 `_resetAudioAttachment()`，重开后从 controller 传入的权威位置恢复，不使用 backend 可能瞬时归零的 `_position`。

- [ ] **Step 5: Route repeated boundary errors through safe rebuild**

controller 的恢复候选第一次仍尝试当前线路，但调用 adapter 的 `rebuildDecoder(_recoveryPosition)`；刷新 URL、降清晰度或换线路时仍调用 `_open`。pending seek 存在时 backend 的 zero 不进入 `onProgress`，因此不会覆盖历史。

- [ ] **Step 6: Run boundary and integration tests**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; dart format lib\features\anime\playback\player_adapter.dart lib\features\anime\playback\media_kit_player_adapter.dart lib\features\anime\playback\playback_session_controller.dart test\media_kit_player_adapter_test.dart test\playback_session_controller_test.dart test\anime_player_page_test.dart test\anime_playback_integration_test.dart; flutter test test\media_kit_player_adapter_test.dart test\playback_session_controller_test.dart test\anime_player_page_test.dart test\anime_playback_integration_test.dart'
```

Expected: all selected tests PASS; decoder rebuild clears old external audio, resumes at a non-zero authoritative position, and history never regresses to zero.

- [ ] **Step 7: Commit decoder boundary recovery**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; git add lib\features\anime\playback\player_adapter.dart lib\features\anime\playback\media_kit_player_adapter.dart lib\features\anime\playback\playback_session_controller.dart test\media_kit_player_adapter_test.dart test\playback_session_controller_test.dart test\anime_player_page_test.dart test\anime_playback_integration_test.dart; git commit -m ''fix(anime): rebuild decoder across media boundaries'''
```

### Task 6: Focused Verification Without Packaging

**Files:**
- Verify: all files listed above

- [ ] **Step 1: Run the focused playback suite**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; flutter test test\playback_session_controller_test.dart test\media_kit_player_adapter_test.dart test\anime_player_controls_test.dart test\anime_player_page_test.dart test\hls_media_rewriter_test.dart test\hls_cache_gateway_test.dart test\hls_cache_store_test.dart test\anime_playback_integration_test.dart'
```

Expected: all focused playback, gateway, cache and widget tests PASS without a hanging test process.

- [ ] **Step 2: Run focused static analysis**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; dart analyze lib\features\anime\anime_player_page.dart lib\features\anime\anime_player_controls.dart lib\features\anime\playback test\playback_session_controller_test.dart test\media_kit_player_adapter_test.dart test\anime_player_controls_test.dart test\anime_player_page_test.dart test\hls_media_rewriter_test.dart test\hls_cache_gateway_test.dart test\hls_cache_store_test.dart test\anime_playback_integration_test.dart'
```

Expected: `No issues found!`.

- [ ] **Step 3: Check formatting, scope and commit history**

```powershell
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
& $pwsh -NoProfile -Command '$ErrorActionPreference = ''Stop''; git diff --check; git status --short --branch; git log --oneline cd948bb..HEAD'
```

Expected: `git diff --check` has no output; the worktree is clean; the range contains only the five implementation commits from this plan.

- [ ] **Step 4: Stop at the agreed boundary**

Do not run Windows or Android builds, do not package, do not perform real-device source playback, and do not push. Report the focused test/analyzer evidence and the remaining real-device risk for third-party ad streams.
