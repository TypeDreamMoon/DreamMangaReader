# Hertz 应用数据 SDK — Dart

> 和 C++ / TS 版是**同一套设计**：方法名、错误语义、重试策略、版本语义全部一致。
> 学会一个就够。

## 状态（2026-10-24）

| | |
|---|---|
| 代码 | ✅ 写完 |
| 依赖 | **零第三方依赖**（网络用 `dart:io`，SHA-256 自己算） |
| 测试 | ✅ **52 项全过，不需要启服务、不需要 `pub get`** |
| 用途 | Flutter（Windows / Android / iOS / macOS / Linux）。Web 不行——`dart:io` 在 Web 上不可用 |

## 快速开始

```dart
import 'package:hertz_sdk/hertz_sdk.dart';

final client = HertzClient(HertzClientOptions(
  baseUrl: 'https://api.example.com',
  appId: 'dream_manga_reader',
  tokenProvider: () async => await getAccessToken(),  // 支持异步，好接续期
  onRetry: (info) => log(info.toString()),           // 重试要看得见
));

// 存一份存档（原始字节，服务端不解析）
final bytes = await File('ROSPlayerData.sav').readAsBytes();
final meta = await client.save('save:slot1', bytes);
// meta.version 是内容哈希，留着做下次写入的 ifMatch

// 读回来
final doc = await client.load('save:slot1');
doc.data;     // Uint8List，和存进去的一模一样
doc.version;

// 只要元信息，不下载内容（每天先比版本用这个）
final head = await client.loadMeta('save:slot1');
head.version;
head.bytes;

// 条件读取：版本一样就 304，一个字节都不传
final r = await client.loadIfChanged('save:slot1', lastVersion);
if (r.notModified) {
  // 用本地那份
} else {
  // 用 r.doc
}

// 冲突处理
try {
  await client.save('save:slot1', newBytes, SaveOptions(ifMatch: meta.version));
} on HertzException catch (e) {
  if (e.isConflict) {
    // 别处已经写过一版了 —— 这里要让玩家选
  }
}

// 列出全部（自动翻页）
await for (final m in client.list(const ListOptions(prefix: 'save:'))) {
  print('${m.key} ${m.bytes} ${m.version}');
}

// 上报给社区页看的摘要
await client.publishSummary({'level': 42, 'chapter': 8});

// 读别人公开的摘要（返回原始 JSON 文本）
final json = await client.readSummary('alice');
```

## 测试

```bash
dart run test/run_tests.dart
```

不需要启服务，也不需要 `pub get`——测试用假网络层，`import` 走相对路径。

## 和 C++ / TS 一致的地方（故意保持一致的）

| 项 | 约定 |
|---|---|
| 方法名 | `save` / `load` / `remove` / `list` / `publishSummary` / `readSummary`；另有 `loadMeta` / `loadIfChanged`（C++、Dart 已有，TS 待补） |
| 错误判断 | `isNotFound` / `isConflict` / `isUnauthorized` / `isTooLarge` / `isNetwork`，另有 `code`（服务端业务码） |
| 重试 | 只重试网络错误 + 5xx + 429 + **408**；指数退避 + 抖动；有上限 |
| `Retry-After` | 429 时按服务端说的等 |
| 401 | 自动换 token 重试一次（single-flight，并发只刷一次） |
| `ifMatch` 语义 | `""` 不检查 / `"*"` 只创建 / 具体值乐观锁 |
| 409 幂等确认 | 带具体版本号时，先 `load` 比内容哈希；一致就按成功返回 |
| 版本号 | 内容 SHA-256（服务端算的，客户端可复算） |
| 压缩 | **SDK 不管**，调用方负责 |

**和 C++ 的差异（语言导致的）**

| 项 | C++ | Dart |
|---|---|---|
| 阻塞 | 同步阻塞，必须丢后台线程 | 天生异步，直接 `await` |
| 分页 | `std::vector` 一次拿全 | `Stream<DocMeta>`，边翻边吐 |
| 取消 | 没有 | 暂时没有（`dart:io` 的 HttpClient 不支持单请求取消） |
| 错误 | 抛 `hertz::Error` | 抛 `HertzException` |

## 已知的不足

- **没有进度回调** —— 上传大档时 UI 只能转圈。要做得换 `HttpClient` 的手写流式写入。
- **没有取消** —— 请求发出后只能等超时（默认 30s）。
- **没有连接池参数** —— `IoTransport` 复用同一个 `HttpClient`，但没有暴露最大连接数/空闲超时。
- **`list()` 是流式，但调用方如果用 `.toList()` 就等于一次拿全** —— 数据量大时自己注意。
- **Web 不支持** —— `dart:io` 在 Web 上不可用；要支持 Web 得再写一个基于 `package:http` 的 `HertzTransport`。
- **没有重试的幂等键** —— 靠「内容哈希 + PUT 幂等」保证安全，非幂等操作（将来若有）需要单独的键。

## 目录

```
lib/
  hertz_sdk.dart      统一导出
  src/
    client.dart       主客户端（唯一请求出口，重试/鉴权/错误映射都在里面）
    error.dart        HertzException + HertzErrorKind
    types.dart        DocMeta / LoadedDoc / SaveOptions / LoadResult
    transport.dart    HertzTransport 接口 + dart:io 默认实现
    sha256.dart       SHA-256（409 幂等确认、下载自校验用）
test/
  run_tests.dart      52 项，假网络层
```
