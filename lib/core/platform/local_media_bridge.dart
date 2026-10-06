import 'dart:io';

import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 用户在系统选择器里选中的一个位置:一个目录,或单独几个文件里的一个。
class PickedLocalLocation {
  const PickedLocalLocation({
    required this.uri,
    required this.name,
    required this.kind,
  });

  /// SAF 的 tree uri(目录)或 document uri(文件),已取持久读授权。
  final String uri;

  /// 展示名(目录名/文件名);provider 不给时退回 uri 的最后一段。
  final String name;

  /// 这个位置是目录还是单个文件,决定本地库的类型。
  final LocalLibraryKind kind;

  @override
  String toString() => 'PickedLocalLocation($name, ${kind.name})';
}

/// 一个本地媒体文件在 SAF 里的样子(扫描/查询的结果)。
class LocalMediaEntry {
  const LocalMediaEntry({
    required this.uri,
    required this.name,
    required this.mime,
    required this.size,
    required this.lastModified,
  });

  /// document uri。
  final String uri;

  /// 文件名(不含路径)。
  final String name;

  /// MIME,如 `video/mp4`;provider 不给时是空串。
  final String mime;

  /// 字节数;provider 报未知时是 0。
  final int size;

  /// 修改时间(epoch ms);取不到是 0。增量扫描比 size + mtime(规格 §7.1)。
  final int lastModified;

  @override
  String toString() => 'LocalMediaEntry($name, $size)';
}

/// [LocalMediaBridge.openFd] 的结果。
class OpenedLocalFd {
  const OpenedLocalFd({required this.fd, required this.path});

  /// 进程内的文件描述符号,交给 [LocalMediaBridge.releaseFd] 释放。
  final int fd;

  /// **原样**是 `/proc/self/fd/<fd>`,不做任何 Uri 包装或规范化 ——
  /// 播放层自己按需要 `Uri.file(path)`(规格 §7.2 路线 A)。
  final String path;

  @override
  String toString() => 'OpenedLocalFd($fd)';
}

/// 解析原生回的一个位置(map)。
///
/// 纯函数,单独拎出来是为了能不过平台通道直接测(拿不到 uri 就没有意义,返回 null)。
PickedLocalLocation? parsePickedLocalLocation(
  Object? value, {
  required LocalLibraryKind kind,
}) {
  if (value is! Map) return null;
  final uri = value['uri'];
  if (uri is! String || uri.isEmpty) return null;
  final name = value['name'];
  return PickedLocalLocation(
    uri: uri,
    name: name is String && name.isNotEmpty ? name : _lastSegment(uri),
    kind: kind,
  );
}

/// 解析原生回的一个媒体条目(map)。
///
/// `stat` 的返回里没有 uri(uri 是调用方给的),用 [uri] 兜底;拿不到 uri 返回 null。
LocalMediaEntry? parseLocalMediaEntry(Object? value, {String? uri}) {
  if (value is! Map) return null;
  final rawUri = value['uri'];
  final resolved = rawUri is String && rawUri.isNotEmpty ? rawUri : uri;
  if (resolved == null || resolved.isEmpty) return null;
  final name = value['name'];
  final mime = value['mime'];
  return LocalMediaEntry(
    uri: resolved,
    name: name is String ? name : '',
    mime: mime is String ? mime : '',
    size: parseIntOrZero(value['size']),
    lastModified: parseIntOrZero(value['lastModified']),
  );
}

/// 把原生回的 size/mtime 转成 int。
///
/// 同一个字段可能是 num(Kotlin 的 Long),也可能是 String —— 有些 provider 的
/// `_size` 列本来就是文本。负数是 provider 表示「不知道」的惯用手法,一律按 0 处理。
int parseIntOrZero(Object? value) {
  int parsed = 0;
  if (value is num) {
    parsed = value.toInt();
  } else if (value is String) {
    parsed = int.tryParse(value) ?? 0;
  }
  return parsed < 0 ? 0 : parsed;
}

String _lastSegment(String uri) {
  final trimmed = uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

/// 本地播放的 Android 平台桥(channel `dream_manga_reader/local_media`)。
///
/// **为什么不用 `file_picker` 选视频**:它在 Android 上会把选中的文件整份复制到
/// `cacheDir/file_picker/<时间戳>/<名字>`(`FileUtils.kt:533-575 openFileStream`),
/// 挑一个 4GB 的电影会先复制 4GB。SAF 拿到的是 uri,读的时候是 fd/流,没有第二份拷贝。
///
/// 非 Android 平台每个方法都抛 [UnsupportedError](Windows 走完全不同的实现),
/// 不静默返回空 —— 「这个平台不支持」和「用户没选」是两件事。
class LocalMediaBridge {
  LocalMediaBridge({MethodChannel? channel, bool? isAndroid})
      : channel = channel ?? const MethodChannel(channelName),
        isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  /// 与 `local/LocalMediaBridge.kt` 里的 `METHOD_CHANNEL` 必须一致。
  static const String channelName = 'dream_manga_reader/local_media';

  final MethodChannel channel;

  /// 默认取 `Platform.isAndroid`;只有单测会显式传(测试里不碰真的平台通道)。
  final bool isAndroid;

  /// 让用户挑一个目录。用户取消返回 null(取消不是错误)。
  Future<PickedLocalLocation?> pickDirectory() async {
    _ensureSupported();
    final raw = await channel.invokeMethod<Object?>('pickDirectory');
    if (raw == null) return null;
    return parsePickedLocalLocation(raw, kind: LocalLibraryKind.folder);
  }

  /// 让用户挑若干个视频文件。用户取消返回空列表。
  Future<List<PickedLocalLocation>> pickFiles() async {
    _ensureSupported();
    final raw = await channel.invokeMethod<Object?>('pickFiles');
    if (raw is! List) return const <PickedLocalLocation>[];
    final picked = <PickedLocalLocation>[];
    for (final entry in raw) {
      final location = parsePickedLocalLocation(entry, kind: LocalLibraryKind.file);
      if (location != null) picked.add(location);
    }
    return picked;
  }

  /// 递归列出 [treeUri] 下的所有文件条目(子目录一路走下去,目录本身不入结果)。
  ///
  /// 扫到一半没了权限时原生会保留已扫到的条目正常返回(规格 §9)。
  Future<List<LocalMediaEntry>> listChildren(String treeUri) async {
    _ensureSupported();
    final raw = await channel.invokeMethod<Object?>(
      'listChildren',
      <String, Object?>{'treeUri': treeUri},
    );
    if (raw is! List) return const <LocalMediaEntry>[];
    final entries = <LocalMediaEntry>[];
    for (final entry in raw) {
      final parsed = parseLocalMediaEntry(entry);
      if (parsed != null) entries.add(parsed);
    }
    return entries;
  }

  /// 查一个文档的名字/大小/类型/修改时间。
  ///
  /// 文件被删掉或授权失效时返回 null(原生不抛)—— 调用方据此把它标成「不可用」,
  /// 而不是把一次误报当崩溃。
  Future<LocalMediaEntry?> stat(String uri) async {
    _ensureSupported();
    final raw = await channel.invokeMethod<Object?>(
      'stat',
      <String, Object?>{'uri': uri},
    );
    return parseLocalMediaEntry(raw, uri: uri);
  }

  /// 打开 [uri] 的文件描述符。
  ///
  /// 描述符由原生桥持有,**不会**在返回后关闭;读完了必须 [releaseFd]。
  /// 拿到的 [OpenedLocalFd.path] 是 `/proc/self/fd/<fd>`,可以直接喂给同进程的 mpv
  /// (路线 A,规格 §7.2);真机是否被 mpv 接受由 spike 验证。
  Future<OpenedLocalFd> openFd(String uri) async {
    _ensureSupported();
    final raw = await channel.invokeMethod<Object?>(
      'openFd',
      <String, Object?>{'uri': uri},
    );
    if (raw is! Map) {
      throw PlatformException(
        code: 'invalid_fd',
        message: '原生没有返回文件描述符',
      );
    }
    final fd = parseIntOrZero(raw['fd']);
    final path = raw['path'];
    if (fd <= 0 || path is! String || path.isEmpty) {
      throw PlatformException(
        code: 'invalid_fd',
        message: '原生返回的文件描述符不可用',
      );
    }
    return OpenedLocalFd(fd: fd, path: path);
  }

  /// 释放 [openFd] 拿到的描述符。**幂等**:同一个 fd 释放两次不会抛
  /// (播放页的异常路径上会重复释放),所以这里不记状态。
  Future<void> releaseFd(int fd) async {
    _ensureSupported();
    await channel.invokeMethod<void>('releaseFd', <String, Object?>{'fd': fd});
  }

  /// 让 provider 删除一个文档/tree。
  ///
  /// 只在「应用内移除库且用户显式确认删源文件」时调用,默认不调 ——
  /// 移除库的正常语义是只删索引,不动用户的文件(规格 §8.2)。
  Future<void> deleteTree(String uri) async {
    _ensureSupported();
    await channel.invokeMethod<void>('deleteTree', <String, Object?>{'uri': uri});
  }

  void _ensureSupported() {
    if (!isAndroid) throw UnsupportedError('本地媒体桥仅支持 Android');
  }
}
