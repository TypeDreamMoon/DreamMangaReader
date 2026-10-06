/// Android 的目录遍历：走 SAF 桥的 `listChildren`（原生递归，一次调用拿全部）。
///
/// 对应设计文档 docs/superpowers/specs/2026-09-30-local-playback-design.md
/// §7.2（Android 路线 A）、§9（权限失效与跳过计数）。
///
/// 与 `DartIoDirectoryWalker` 的差别不止「谁来读目录」：
/// - 原生 `listChildren` 已经把子树走完，所以这里是**一趟扁平结果**，不自己递归；
/// - 分组键（`directoryKey`）没有「目录路径」可以直接用（返回的只有文件 uri），
///   只能从 document id 反推父目录 —— 见 [safDirectoryKey]；
/// - 「读不到的目录」由原生跳过（`SecurityException` 时不中断，保留已扫到的条目），
///   所以本文件的 [skippedDuringWalk] 一般恒为 0，只在条目连名字都拿不到时才累加。
///
/// 与桥一样：非 Android 平台调用会抛 [UnsupportedError]（由桥抛出），
/// 不静默返回空列表 —— 「这个平台不支持」和「目录是空的」是两件事。
library;

import '../platform/local_media_bridge.dart';
import 'local_episode_parser.dart';
import 'local_library_scanner.dart';

/// 用 SAF 桥递归列出一个 tree uri 下的全部文件。
class SafDirectoryWalker implements LocalDirectoryWalker, LocalWalkSkipReport {
  SafDirectoryWalker(this.bridge);

  final LocalMediaBridge bridge;

  int _skipped = 0;

  /// 每扫到这么多条就让出一次事件循环，免得长列表把 UI 卡住。
  static const int _yieldEvery = 200;

  /// 上一次遍历中「连文件名都拿不到」的条目数。
  ///
  /// 权限失效这类整目录级的失败由桥/原生吞掉（保留已扫到的条目），不会走到这里；
  /// 这个计数只是为了让接口完整：walker 自报它自己丢掉了什么，扫描器照单累加。
  @override
  int get skippedDuringWalk => _skipped;

  @override
  Future<List<LocalFileEntry>> walk(
    String root, {
    void Function(int found)? onProgress,
  }) async {
    _skipped = 0;
    // 整次扫描失败（桥不可用、平台不对、原生抛错）→ 直接抛，交给扫描器转成提示。
    final entries = await bridge.listChildren(root);
    final result = <LocalFileEntry>[];
    for (final entry in entries) {
      final name = entry.name.isNotEmpty ? entry.name : safLastSegment(entry.uri);
      if (name.isEmpty || entry.uri.trim().isEmpty) {
        _skipped++;
        continue;
      }
      result.add(
        LocalFileEntry(
          location: entry.uri,
          name: name,
          directoryKey: safDirectoryKey(entry.uri),
          size: entry.size,
          // 0 是「provider 不知道」，不是「1970 年」。
          modifiedAt: entry.lastModified > 0 ? entry.lastModified : null,
        ),
      );
      if (result.length % _yieldEvery == 0) {
        onProgress?.call(result.length);
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress?.call(result.length);
    return result;
  }
}

/// 从文件的 document uri 反推**父目录**的分组键。
///
/// SAF 的 document uri 形如
/// `content://com.android.externalstorage.documents/tree/primary%3AMovies/document/primary%3AMovies%2FShow%2FE01.mkv`
/// —— `Uri.pathSegments` 会把最后一段解成 `primary:Movies/Show/E01.mkv`，
/// 去掉最后一级就是父目录 `primary:Movies/Show`。
///
/// 拿不到可信结构时退回 uri 自身：这时「同目录」的判断会退化成「每个文件各自一组」，
/// 结果是字幕配不上对（可接受的降级），而不是把不同目录的文件错配成一组。
String safDirectoryKey(String uri) {
  final trimmed = uri.trim();
  if (trimmed.isEmpty) return '';
  final segments = _segmentsOf(trimmed);
  if (segments == null || segments.isEmpty) return trimmed;
  return _parentDocumentId(segments.last);
}

/// uri 的最后一段（文件名/目录名）；拿不到就返回 uri 自身。
String safLastSegment(String uri) {
  final trimmed = uri.trim();
  if (trimmed.isEmpty) return '';
  final segments = _segmentsOf(trimmed);
  if (segments == null || segments.isEmpty) return trimmed;
  // document id 里还可能带 `/`（`primary:Movies/E01.mkv`），再取一次末段。
  final documentId = segments.last;
  final name = _lastPathSegment(documentId);
  return name.isEmpty ? documentId : name;
}

/// uri 的非空 path 段；uri 结构不可信（[FormatException]）时返回 null。
///
/// 解析细节见 [safDirectoryKey] 的说明，两个函数共用这一份解析。
List<String>? _segmentsOf(String trimmed) {
  try {
    return Uri.parse(trimmed)
        .pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
  } on FormatException {
    return null;
  }
}

String _parentDocumentId(String documentId) {
  final cut = documentId.lastIndexOf('/');
  // 没有父目录（`primary:Movies` 这种根级 document）→ 自己当分组键。
  if (cut <= 0) return documentId;
  return documentId.substring(0, cut);
}

String _lastPathSegment(String documentId) {
  final cut = documentId.lastIndexOf('/');
  return cut < 0 ? documentId : documentId.substring(cut + 1);
}

/// 这个文件能不能进本地库（扩展名白名单，与扫描器同源）。
///
/// 桥的 `listChildren` 会连 `.jpg`、`.nfo` 一起返回，筛掉它们的是扫描器；
/// 这里单独暴露一个判定只是给「挑文件」那条路径用（路线 B 没有目录扫描）。
bool isPickableLocalMediaName(String fileName) =>
    isVideoFileName(fileName) || isAudioFileName(fileName);
