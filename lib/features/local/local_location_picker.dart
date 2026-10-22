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
    return picked == null ? null : _fromBridgeLocation(picked);
  }

  @override
  Future<List<PickedLocation>> pickFiles() async {
    final picked = await bridge.pickFiles();
    return [
      for (final entry in picked) _fromBridgeLocation(entry),
    ];
  }
}

/// SAF 桥的位置 → 页面认的位置(两边字段一一对应,只是换了个名字)。
PickedLocation _fromBridgeLocation(PickedLocalLocation picked) => PickedLocation(
      location: picked.uri,
      name: picked.name,
      kind: picked.kind,
    );

/// Windows / 桌面的实现:走 `file_picker`,拿到的是真实绝对路径。
///
/// 只在需要真实路径的平台用;Android 上必须走 [SafLocalLocationPicker]。
class FilePickerLocalLocationPicker implements LocalLocationPicker {
  const FilePickerLocalLocationPicker();

  @override
  Future<PickedLocation?> pickDirectory() async {
    final path = _nonBlankPath(await FilePicker.getDirectoryPath());
    if (path == null) return null;
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
      final path = _nonBlankPath(file.path);
      if (path == null) continue;
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

/// file_picker 回来的空路径(取消、或拿不到真实路径)= 没挑中;
/// 非空时原样返回,**不做 trim**,免得把用户路径里的空格改掉。
String? _nonBlankPath(String? path) =>
    (path == null || path.trim().isEmpty) ? null : path;

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

/// 反斜杠统一成 `/`,并去掉末尾的 `/`(Windows 路径与 SAF uri 都能过一遍)。
/// 从位置里取名字/父目录的工具在 `core/local/local_models.dart`(core 不该反向
/// 依赖 feature,所以那边是唯一的实现)。

/// 这个平台是否用真实路径(而不是 SAF uri)。
bool localUsesRealPaths({LocalMediaBridge? bridge}) =>
    !(bridge ?? LocalMediaBridge()).isAndroid &&
    (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
