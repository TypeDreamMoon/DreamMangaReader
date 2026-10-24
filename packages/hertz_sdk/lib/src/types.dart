import 'dart:typed_data';

/// 原始字节。二进制存档和 JSON 走同一个类型——服务端不解析内容。
typedef HertzBytes = Uint8List;

/// 读权限：0 只有服务端 / 1 只有本人 / 2 公开
abstract final class PermRead {
  static const server = 0;
  static const owner = 1;
  static const public = 2;
}

/// 写权限：0 只有服务端 / 1 只有本人
abstract final class PermWrite {
  static const server = 0;
  static const owner = 1;
}

/// 一份数据的元信息。
class DocMeta {
  const DocMeta({
    required this.key,
    this.bytes = 0,
    this.contentType = 'application/octet-stream',
    this.version = '',
    this.permRead = PermRead.owner,
    this.permWrite = PermWrite.owner,
    this.updatedAt = '',
  });

  final String key;
  final int bytes;
  final String contentType;

  /// 内容哈希。留着做下次写入的 ifMatch。
  final String version;
  final int permRead;
  final int permWrite;
  final String updatedAt;

  @override
  String toString() => 'DocMeta($key, $bytes bytes, v=$version)';
}

/// 一份读回来的数据。
class LoadedDoc extends DocMeta {
  const LoadedDoc({
    required super.key,
    required this.data,
    super.bytes,
    super.contentType,
    super.version,
    super.permRead,
    super.permWrite,
    super.updatedAt,
  });

  final HertzBytes data;
}

/// 条件 GET 的结果。
///
/// 304 不是错误——它表示「你手上那份还是最新的」，所以单独一个类型，
/// 让调用方在类型层面就必须处理这个分支，而不是去比状态码。
class LoadResult {
  const LoadResult.notModified()
      : notModified = true,
        doc = null;

  const LoadResult.fresh(LoadedDoc this.doc) : notModified = false;

  final bool notModified;
  final LoadedDoc? doc;
}

/// 写入选项。
class SaveOptions {
  const SaveOptions({
    this.permRead = PermRead.owner,
    this.permWrite = PermWrite.owner,
    this.ifMatch = '',
    this.contentType = 'application/octet-stream',
  });

  final int permRead;
  final int permWrite;

  /// 乐观锁。三种语义：
  ///   ""    不检查，直接覆盖
  ///   "*"   只在不存在时创建，已存在则报 Conflict
  ///   其他  必须与当前版本完全一致
  final String ifMatch;
  final String contentType;
}

/// 列目录选项。
class ListOptions {
  const ListOptions({this.prefix = '', this.pageSize = 50});

  final String prefix;
  final int pageSize;
}

/// 一次重试的说明。给 [HertzClient] 的 onRetry 用。
///
/// 静默重试会把系统性问题藏起来——「不能调优你看不见的东西」。
class RetryInfo {
  const RetryInfo({
    required this.attempt,
    required this.delayMs,
    required this.reason,
    required this.status,
    required this.method,
    required this.path,
  });

  final int attempt;
  final int delayMs;
  final String reason;
  final int status;
  final String method;
  final String path;

  @override
  String toString() =>
      '重试第 $attempt 次，等 ${delayMs}ms，HTTP $status，$reason';
}
