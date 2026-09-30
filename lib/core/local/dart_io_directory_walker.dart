/// Windows / 桌面端的目录遍历：`dart:io` 递归，逐目录隔离错误。
///
/// 对应设计文档 docs/superpowers/specs/2026-09-30-local-playback-design.md
/// §7.1（Windows 方案）、§9（长路径与读不到的目录）、§11（每 200 条让出事件循环）。
///
/// 跳过规则（规格 §7.1）：名字以 `.` 开头的隐藏目录、`$RECYCLE.BIN`、
/// `System Volume Information`、`node_modules`，以及**仅当它是 root 直接子目录时**的
/// `Windows`（用户误选 `C:\` 时不至于全盘扫）。这些是刻意的过滤，不计入跳过数。
///
/// 计入 [skippedDuringWalk] 的只有两类：超过 [maxPathLength] 的长路径（Windows 的
/// 260 上限），以及读不到的目录/断链 —— 都是「本想收录但失败了」的条目。
///
/// 为什么不用 `Directory.list(recursive: true)` 的异步流：那个流把「哪个目录读失败」
/// 压成一个没有归属的错误事件，既分不清是**根目录**失败还是某个**子目录**失败，
/// 也没法只跳过失败的那一个目录。这里改成显式队列 + 逐目录 `listSync`：
/// 每个目录单独 try，根目录不可读直接抛（交给扫描器提示），子目录不可读只计数。
library;

import 'dart:io';

import 'local_library_scanner.dart';

/// `dart:io` 的目录遍历实现。
class DartIoDirectoryWalker
    implements LocalDirectoryWalker, LocalWalkSkipReport {
  DartIoDirectoryWalker({this.maxPathLength = 260});

  /// 单个文件路径的长度上限。Windows 传统 `MAX_PATH` = 260；
  /// 超长的文件跳过并计数（规格 §9：不做 `\\?\` 前缀特殊处理）。
  final int maxPathLength;

  int _skipped = 0;

  @override
  int get skippedDuringWalk => _skipped;

  /// 每找到这么多文件就让出一次事件循环并上报一次进度（规格 §11）。
  static const int _yieldEvery = 200;

  /// 一律跳过的目录名（比较时转小写，Windows 大小写不敏感）。
  static const Set<String> _skippedDirectoryNames = <String>{
    r'$recycle.bin',
    'system volume information',
    'node_modules',
  };

  /// 只在 root 的直接子目录里跳过的名字。
  static const Set<String> _rootLevelSkippedNames = <String>{'windows'};

  @override
  Future<List<LocalFileEntry>> walk(
    String root, {
    void Function(int found)? onProgress,
  }) async {
    _skipped = 0;
    final Directory rootDirectory = Directory(root);
    if (!await rootDirectory.exists()) {
      // 根目录都读不到（盘符没挂上、目录被改名/被删）时**不能**静默返回空列表：
      // 那会变成「这个文件夹里没有媒体文件」，把「位置没了」误导成「没有内容」。
      // 抛给扫描器，由它转成提示（异常摘要里不含完整路径）。
      throw FileSystemException('扫描根目录不存在或不可读', root);
    }

    final List<LocalFileEntry> found = <LocalFileEntry>[];
    final List<_PendingDirectory> pending = <_PendingDirectory>[
      _PendingDirectory(rootDirectory, depth: 0),
    ];

    while (pending.isNotEmpty) {
      final _PendingDirectory current = pending.removeLast();
      final List<FileSystemEntity> children;
      try {
        children = current.directory.listSync(followLinks: false)
          // 顺序稳定：结果与 walker 的遍历顺序无关（扫描器会重排），
          // 但稳定顺序让测试和现场排查都少一类「偶尔不一样」。
          ..sort((left, right) => left.path.compareTo(right.path));
      } on FileSystemException {
        // PathAccessException / PathNotFoundException 都是 FileSystemException 的子类：
        // 单个目录读不到只跳过它，不中断整次扫描（规格 §9）。
        _skipped++;
        continue;
      }

      final int childDepth = current.depth + 1;
      for (final FileSystemEntity child in children) {
        final String name = _fileNameOf(child);
        if (child is Directory) {
          if (_shouldSkipDirectory(name, depth: childDepth)) continue;
          // followLinks: false → 目录符号链接不会以 Directory 形态出现，天然不进环。
          pending.add(_PendingDirectory(child, depth: childDepth));
          continue;
        }

        final File? file = _asFile(child);
        if (file == null) continue;

        final String location = file.absolute.path;
        if (location.length > maxPathLength) {
          _skipped++;
          continue;
        }

        int size = 0;
        int? modifiedAt;
        try {
          final FileStat stat = file.statSync();
          size = stat.size;
          modifiedAt = stat.modified.millisecondsSinceEpoch;
        } on FileSystemException {
          // 文件被占用/权限不足导致 stat 失败：位置本身有效，条目照收，
          // 元数据留空（size 0 + modifiedAt null），增量比对时会当成「已变化」重扫。
        }

        found.add(
          LocalFileEntry(
            location: location,
            name: name,
            // 父目录交给 dart:io 的路径 API 推导，不手工截字符串。
            directoryKey: file.parent.absolute.path,
            size: size,
            modifiedAt: modifiedAt,
          ),
        );

        if (found.length % _yieldEvery == 0) {
          await Future<void>.delayed(Duration.zero);
          onProgress?.call(found.length);
        }
      }
    }

    // 收尾再报一次，保证 UI 看到的总数就是最终总数（不整除时最后一次不会漏）。
    if (found.isNotEmpty && found.length % _yieldEvery != 0) {
      onProgress?.call(found.length);
    }
    return found;
  }

  /// 该目录名是否属于「刻意不扫」的名单。[depth] 是它相对 root 的层级（直接子目录为 1）。
  bool _shouldSkipDirectory(String name, {required int depth}) {
    if (name.isEmpty) return false;
    // 隐藏目录（`.git`、`.thumbnails`）：规格 §7.1 明确跳过。
    if (name.startsWith('.')) return true;
    final String lowered = name.toLowerCase();
    if (_skippedDirectoryNames.contains(lowered)) return true;
    if (depth == 1 && _rootLevelSkippedNames.contains(lowered)) return true;
    return false;
  }

  /// 把实体识别成「可收录的文件」；不是文件就返回 null。
  ///
  /// 符号链接在 `followLinks: false` 下以 [Link] 形态出现：
  /// - 指向**文件**的链接 → 收录（用户特意放进来的链接通常是有意的）；
  /// - 指向目录的链接 → 不递归（防环），也不计入跳过数（它不是「读失败」）；
  /// - 断链 → 位置已失效，计入跳过数。
  File? _asFile(FileSystemEntity entity) {
    if (entity is File) return entity;
    if (entity is! Link) return null;
    final FileSystemEntityType type;
    try {
      // 跟随链接看目标类型（默认 followLinks: true）。
      type = FileSystemEntity.typeSync(entity.path);
    } on FileSystemException {
      _skipped++;
      return null;
    }
    if (type == FileSystemEntityType.notFound) {
      _skipped++;
      return null;
    }
    if (type != FileSystemEntityType.file) return null;
    return File(entity.path);
  }

  /// 取路径的最后一段（文件名）。走 dart:io 的 URI 解析，不手工切分隔符。
  ///
  /// 注意：目录的 uri 以 `/` 结尾，`pathSegments` 因此多出一个空串
  /// （`.../System%20Volume%20Information/` → `[..., 'System Volume Information', '']`），
  /// 不去掉的话目录名会变成空串，隐藏目录/回收站过滤就全部失效。
  String _fileNameOf(FileSystemEntity entity) {
    final List<String> segments = entity.uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList();
    return segments.isEmpty ? entity.path : segments.last;
  }
}

/// 待遍历的目录 + 它相对 root 的层级（root 自身是 0）。
class _PendingDirectory {
  const _PendingDirectory(this.directory, {required this.depth});

  final Directory directory;
  final int depth;
}
