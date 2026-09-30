import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../core/local/local_models.dart';
import '../../core/platform/local_media_bridge.dart';

/// 用户在系统选择器里挑中的一个位置:一个目录,或单独挑的几个文件里的一个。
///
/// [location] 的形态与 [LocalMediaItem.location] 完全一致 ——
/// Windows 是绝对路径,Android 是 SAF 的 document/tree uri。上层不需要知道区别。
class PickedLocation {
  const PickedLocation({
    required this.location,
    required this.name,
    required this.kind,
  });

  final String location;

  /// 展示名:目录名或文件名(不保证含扩展名)。
  final String name;

  final LocalLibraryKind kind;

  @override
  String toString() => 'PickedLocation($name, ${kind.name})';
}

/// 「挑位置」的平台抽象。
///
/// 两端用的是完全不同的东西(Windows 的 file_picker 给真实路径,Android 的 SAF
/// 给 uri 且**不复制文件**),但上层只关心「用户挑了什么」,所以在这里切开:
/// 页面与 [LocalLibraryActions] 只依赖这个接口,测试可以注入假实现。
abstract interface class LocalLocationPicker {
  /// 让用户挑一个目录。取消返回 null。
  Future<PickedLocation?> pickDirectory();

  /// 让用户挑若干个文件。取消返回空列表。
  Future<List<PickedLocation>> pickFiles();
}

/// Android 的实现:走 SAF 桥(规格 §7.2)。
///
/// **刻意不用 `file_picker` 选视频**:它在 Android 上会把整个文件复制到
/// `cacheDir/file_picker/...`(FileUtils.kt:533-575),挑一个 4GB 的电影要先复制
/// 一份;SAF 给的是 uri,读的时候是 fd。
class SafLocalLocationPicker implements LocalLocationPicker {
  const SafLocalLocationPicker(this.bridge);

  final LocalMediaBridge bridge;

  @override
  Future<PickedLocation?> pickDirectory() async {
    final picked = await bridge.pickDirectory();
    if (picked == null) return null;
    return PickedLocation(
      location: picked.uri,
      name: picked.name,
      kind: picked.kind,
    );
  }

  @override
  Future<List<PickedLocation>> pickFiles() async {
    final picked = await bridge.pickFiles();
    return [
      for (final entry in picked)
        PickedLocation(
          location: entry.uri,
          name: entry.name,
          kind: entry.kind,
        ),
    ];
  }
}

/// Windows / 桌面的实现:走 `file_picker`,拿到的是真实绝对路径。
///
/// 只在需要真实路径的平台用;Android 上必须走 [SafLocalLocationPicker]。
class FilePickerLocalLocationPicker implements LocalLocationPicker {
  const FilePickerLocalLocationPicker();

  @override
  Future<PickedLocation?> pickDirectory() async {
    final path = await FilePicker.getDirectoryPath();
    if (path == null || path.trim().isEmpty) return null;
    return PickedLocation(
      location: path,
      name: localLocationName(path),
      kind: LocalLibraryKind.folder,
    );
  }

  @override
  Future<List<PickedLocation>> pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: kLocalPickableExtensions,
    );
    if (result == null) return const <PickedLocation>[];
    final picked = <PickedLocation>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null || path.trim().isEmpty) continue;
      picked.add(
        PickedLocation(
          location: path,
          name: file.name,
          kind: LocalLibraryKind.file,
        ),
      );
    }
    return picked;
  }
}

/// 当前平台该用哪个挑选实现。
///
/// 判据是桥的 [LocalMediaBridge.isAndroid](默认 `Platform.isAndroid`),不是
/// `Platform.isAndroid` 本身 —— 测试可以只注入桥就改变行为。
LocalLocationPicker localLocationPickerFor({LocalMediaBridge? bridge}) {
  final resolved = bridge ?? LocalMediaBridge();
  return resolved.isAndroid
      ? SafLocalLocationPicker(resolved)
      : const FilePickerLocalLocationPicker();
}

/// 选择器里允许挑的扩展名(规格 §5.3 的白名单,与 `local_episode_parser.dart` 一致)。
///
/// 扫描器还会再筛一遍,所以这里多一个少一个都不会把不能播的文件放进库;
/// 它只决定系统对话框里的「文件类型」筛选。
const List<String> kLocalPickableExtensions = <String>[
  'mp4',
  'mkv',
  'webm',
  'avi',
  'mov',
  'm4v',
  'ts',
  'm2ts',
  'flv',
  'wmv',
  'mpg',
  'mpeg',
  'ogv',
  'mp3',
  'flac',
  'aac',
  'm4a',
  'ogg',
  'opus',
  'wav',
  'srt',
  'ass',
  'ssa',
  'vtt',
  'sub',
];

/// 从一个位置里取出展示名(Windows 反斜杠也认)。
String localLocationName(String location) {
  final normalized = location.replaceAll(r'\', '/');
  final trimmed =
      normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  final cut = trimmed.lastIndexOf('/');
  final name = cut < 0 ? trimmed : trimmed.substring(cut + 1);
  return name.isEmpty ? trimmed : name;
}

/// Windows 上取一个路径的父目录;没有父目录时返回它自己。
String localLocationParent(String location) {
  final normalized = location.replaceAll(r'\', '/');
  final trimmed =
      normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  final cut = trimmed.lastIndexOf('/');
  if (cut <= 0) return trimmed;
  return trimmed.substring(0, cut);
}

/// 这个平台是否用真实路径(而不是 SAF uri)。
bool localUsesRealPaths({LocalMediaBridge? bridge}) =>
    !(bridge ?? LocalMediaBridge()).isAndroid &&
    (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
