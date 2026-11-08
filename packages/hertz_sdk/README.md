# Hertz 应用数据 SDK — Dart

> 和 C++ / TS 版是**同一套设计**：方法名、错误语义、重试策略、版本语义全部一致。
> 学会一个就够。

## 状态（2026-11-08）

| | |
|---|---|
| 代码 | ✅ 写完 |
| 依赖 | **零第三方依赖**（网络用 `dart:io`，SHA-256 自己算） |
| 测试 | ✅ **72 项全过，不需要启服务、不需要 `pub get`**（`IoTransport` 那几项用进程内的回环服务） |
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

// 第一次写（手上没有版本号）：只创建。别不带条件——那等于「最后写入者赢」
await client.save('save:slot1', bytes, const SaveOptions(createOnly: true));

// 冲突处理
try {
  await client.save('save:slot1', newBytes, SaveOptions(ifMatch: meta.version));
} on HertzException catch (e) {
  if (e.isConflict) {
    // 别处已经写过一版了 —— 这里要让玩家选
  } else if (e.isPreconditionFailed) {
    // 412：记录已经不在了（被删了）—— 没有「当前版本」可比，按首写处理
  }
}

// 404 分两种：数据服务说「没有这条」（code == HertzErrorCode.notFound），
// 和地址配错了（别的服务 / 反代回的 404，code == 0）。只有前者能当「云端没数据」。

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

## 端到端（需要一个在跑的服务）

```bash
dart run test/e2e_local.dart                 # 默认 http://127.0.0.1:8083
BASE=http://127.0.0.1:8083 dart run test/e2e_local.dart
```

前提：`appdata` 服务在线且 `APPDATA_AUTH_MODE=dev`（脚本会自己调 `/dev/token`）。
会真连 HTTP + PostgreSQL，验 17 项：save/load 往返一致、`version == SHA-256`、
HEAD 元信息、304 条件 GET、If-Match 乐观锁、过期 If-Match → 409、`list(prefix)`、
跨用户读公开摘要、匿名读 401、remove 后 404。

## 和 C++ / TS 一致的地方（故意保持一致的）

| 项 | 约定 |
|---|---|
| 方法名 | `save` / `load` / `remove` / `list` / `publishSummary` / `readSummary`；另有 `loadMeta` / `loadIfChanged`（C++、Dart 已有，TS 待补） |
| 错误判断 | `isNotFound` / `isConflict` / `isPreconditionFailed`（412）/ `isUnauthorized` / `isTooLarge` / `isNetwork`，另有 `code`（服务端业务码，常量见 `HertzErrorCode`；HEAD 没有 body 时取 `X-Error-Code` 头） |
| 重试 | 只重试网络错误 + 5xx + 429 + **408**；指数退避 + 抖动；有上限 |
| `Retry-After` | 429 时按服务端说的等 |
| 401 | 自动换 token 重试一次（single-flight，并发只刷一次） |
| `ifMatch` 语义 | `""` 不检查 / `"*"` **只更新**（记录不存在 → 412）/ 具体值乐观锁（版本不同 → 409，记录不存在 → 412） |
| 只创建 | `createOnly: true` → `If-None-Match: *`（已存在 → 409）。**不是** `ifMatch: "*"`。Dart 先有，C++ / TS 待补 |
| 409 幂等确认 | 带具体版本号或 `createOnly` 时，先 `load` 比内容哈希；一致就按成功返回 |
| 版本号 | 内容 SHA-256（服务端算的，客户端可复算） |
| 压缩 | **SDK 不管**，调用方负责 |

**和 C++ 的差异（语言导致的）**

| 项 | C++ | Dart |
|---|---|---|
| 阻塞 | 同步阻塞，必须丢后台线程 | 天生异步，直接 `await` |
| 分页 | `std::vector` 一次拿全 | `Stream<DocMeta>`，边翻边吐 |
| 取消 | 没有 | 暂时没有（`dart:io` 的 HttpClient 不支持单请求取消） |
| 错误 | 抛 `hertz::Error` | 抛 `HertzException` |

## 变更

**2026-11-08**
- 新增 `SaveOptions.createOnly`（`If-None-Match: *`）。之前文档说 `ifMatch: "*"` 是「只创建」——**错的**：
  服务端把 `If-Match: *` 当「只更新」（记录不存在回 412）。首写请改用 `createOnly`。
- 新增 `HertzErrorKind.preconditionFailed` / `isPreconditionFailed`（412，以前落在 `badRequest`）
  和 `HertzErrorCode`（契约里的业务码）。
- `code` 在响应没有 body 时（HEAD）取 `X-Error-Code` 头。
- `save()` 的 version：信封里没有时退回 `X-Version` 头。
- `IoTransport`：PUT / POST 声明 `Content-Length`（以前走 chunked，appdata 对 chunked 回 400）；
  响应体加空闲超时，超时掐连接。

## 已知的不足

- **没有进度回调** —— 上传大档时 UI 只能转圈。要做得换 `HttpClient` 的手写流式写入。
- **没有取消** —— 请求发出后只能等超时（默认 30s）。超时分段计：建连、发完请求体到收到响应头、
  读响应体时**两块数据之间**（空闲超时），任何一段超时都会掐掉连接再抛，不会挂死在半截响应体上。
- **没有连接池参数** —— `IoTransport` 复用同一个 `HttpClient`，但没有暴露最大连接数/空闲超时。
- **`list()` 是流式，但调用方如果用 `.toList()` 就等于一次拿全** —— 数据量大时自己注意。
- **Web 不支持** —— `dart:io` 在 Web 上不可用；要支持 Web 得再写一个基于 `package:http` 的 `HertzTransport`。
- **没有重试的幂等键** —— 靠「内容哈希 + PUT 幂等」保证安全，非幂等操作（将来若有）需要单独的键。
- **`perm_read = 2` 不等于匿名可读** —— 服务端 `/api/v1/public/*` 也挂了鉴权中间件，
  所以它的实际语义是「**登录后**跨用户可读」。要真匿名分享，得单独做签名 URL，不要直接放开这个路由。

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
  run_tests.dart      72 项，假网络层 + 回环服务
  e2e_local.dart      端到端，需要一个在跑的 appdata（dev 模式）
```
