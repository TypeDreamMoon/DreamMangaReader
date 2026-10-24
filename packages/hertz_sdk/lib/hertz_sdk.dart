/// Hertz 应用数据 SDK（Dart）。
///
/// 方法名、错误语义、重试策略、版本语义与 C++ / TS 版保持一致。
library;

export 'src/client.dart' show HertzClient, HertzClientOptions;
export 'src/error.dart' show HertzErrorKind, HertzException, kindFromStatus;
export 'src/sha256.dart' show sha256Hex;
export 'src/transport.dart'
    show HertzRequest, HertzResponse, HertzTransport, IoTransport;
export 'src/types.dart';
