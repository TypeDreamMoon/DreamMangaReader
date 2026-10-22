import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../app/local_media_store.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/local/dart_io_directory_walker.dart';
import '../../core/local/local_episode_parser.dart';
import '../../core/local/local_library_scanner.dart';
import '../../core/local/local_models.dart';
import '../../core/local/saf_directory_walker.dart';
import '../../core/platform/local_media_bridge.dart';
import '../../ui/app_notify.dart';
import 'local_location_picker.dart';

/// 提示回调:页面把它接到 `showAppNotify(context, message, kind: kind)`。
typedef LocalLibraryReporter = void Function(String message, AppNotifyKind kind);

/// 本地库的「加库 / 重扫」编排。
///
/// 页面不该知道这些东西:一端用 file_picker、一端用 SAF 桥;一端递归 dart:io、
/// 一端走原生 `listChildren`;扫完还要按 `dedupeKey` 合并进索引。全部收在这里,
/// 页面只负责「按钮 → 一个 Future → 一句提示」。
///
/// 依赖全部可注入,所以整条编排(含失败与重复)能在单测里跑,不需要平台通道。
class LocalLibraryActions {
  LocalLibraryActions({
    required this.store,
    required this.l10n,
    LocalMediaBridge? bridge,
    LocalLocationPicker? picker,
    LocalDirectoryWalker? windowsWalker,
    this.androidWalker,
    bool? windows,
    this.report,
  })  : bridge = bridge ?? LocalMediaBridge(),
        picker = picker ?? localLocationPickerFor(bridge: bridge),
        windowsWalker = windowsWalker ?? DartIoDirectoryWalker(),
        windows = windows ?? Platform.isWindows;

  final LocalMediaStore store;
  final AppLocalizations l10n;
  final LocalMediaBridge bridge;
  final LocalLocationPicker picker;
  final LocalDirectoryWalker windowsWalker;

  /// Android 的遍历实现;**没注入桥时是 null**,`rescan` 会自己按需建一个。
  final LocalDirectoryWalker? androidWalker;

  final bool windows;
  final LocalLibraryReporter? report;

  /// 提示的唯一出口:页面把它接到 `showAppNotify(context, message, kind: kind)`,
  /// 测试里只记消息。没接就是不提示(所有分支都允许静默)。
  void _notify(String message, AppNotifyKind kind) => report?.call(message, kind);

  /// 路线 A:挑一个目录 → 建库 → 立刻扫一遍(规格 §8.1)。
  ///
  /// 用户取消、位置重复、扫描失败都返回 null(已经 [report] 过),不向上抛 ——
  /// 这些都不是异常路径,页面不该为它们写 `try/catch`。
  Future<LocalLibrary?> addFolder() async {
    final PickedLocation? picked;
    try {
      picked = await picker.pickDirectory();
    } on Object catch (error) {
      _reportError(error);
      return null;
    }
    if (picked == null) return null;
    final library = await _create(
      name: picked.name.isEmpty ? l10n.local_unknownTitle : picked.name,
      kind: LocalLibraryKind.folder,
      path: windows ? picked.location : null,
      treeUri: windows ? null : picked.location,
    );
    if (library == null) return null;
    await rescan(library);
    return library;
  }

  /// 路线 B:挑若干个文件 → **按「同剧」分组**建库 / 并入已有库(不复制文件,
  /// 只记路径/uri)。
  ///
  /// 分组规则见 [groupLocalItemsForLibraries]:带季集号的按归一化剧名归堆,命中的
  /// 已有**文件型**库直接追加条目 —— 这就是「一部剧加两集变成两张卡」的正面解法。
  /// 一次挑了两部剧就会建/并两个库。
  ///
  /// 挑进来的文件里不是媒体的(用户手滑选了 `.txt`)不算错误,只是不入选;
  /// 全都不是媒体才提示一句「不支持」。
  ///
  /// 返回值取**第一组**的结果(页面只用它判断成功与否,不关心是哪一组)。
  Future<LocalLibrary?> addFiles() async {
    final List<PickedLocation> picked;
    try {
      picked = await picker.pickFiles();
    } on Object catch (error) {
      _reportError(error);
      return null;
    }
    if (picked.isEmpty) return null;
    final items = _itemsFromPicked(picked);
    if (items.isEmpty) {
      _notify(l10n.local_emptyUnsupported, AppNotifyKind.warn);
      return null;
    }

    LocalLibrary? first;
    final done = <String>[];
    for (final group in groupLocalItemsForLibraries(items)) {
      final merged = await _mergeIntoExisting(group);
      final LocalLibrary? library;
      if (merged != null) {
        library = merged;
        done.add(l10n.local_mergedInto(merged.name));
      } else {
        final name = group.name.trim();
        library = await _create(
          name: name.isEmpty ? l10n.local_unknownTitle : name,
          kind: LocalLibraryKind.file,
          items: group.items,
        );
        if (library != null) done.add(l10n.local_createdLibrary(library.name));
      }
      first ??= library;
    }
    if (done.isNotEmpty) _notify(done.join('、'), AppNotifyKind.success);
    return first;
  }

  /// 改一个本地库的名字(规格 §5.6)。只有空白时由 store 抛错,这里转成提示。
  Future<bool> renameLibrary(LocalLibrary library, String name) async {
    try {
      await store.renameLibrary(library.id, name);
    } on LocalMediaException catch (error) {
      _notify(error.message, AppNotifyKind.error);
      return false;
    }
    _notify(l10n.local_renamed, AppNotifyKind.success);
    return true;
  }

  /// 改一个条目的显示名;[title] 为空表示恢复解析出来的原名。
  Future<bool> renameItem(LocalMediaItem item, String title) async {
    try {
      await store.renameItem(item.id, title);
    } on LocalMediaException catch (error) {
      _notify(error.message, AppNotifyKind.error);
      return false;
    }
    _notify(l10n.local_renamed, AppNotifyKind.success);
    return true;
  }

  /// 重新扫描一个目录型本地库(规格 §8.4)。
  ///
  /// 只做「目录 → 条目」这件事:条目的 id/播放记录由
  /// [LocalMediaStore.applyScanResult] 按 `dedupeKey` 保住,重扫不会清空历史。
  /// 文件型库(用户单独挑的几个文件)没有可枚举的根,返回 null。
  Future<LocalMediaScanSummary?> rescan(LocalLibrary library) async {
    if (library.kind != LocalLibraryKind.folder) return null;
    final root = windows ? library.path : library.treeUri;
    if (root == null || root.trim().isEmpty) {
      _notify(l10n.local_emptyHint, AppNotifyKind.warn);
      return null;
    }
    _notify(l10n.local_scanning, AppNotifyKind.info);
    final scanner = LocalLibraryScanner(walker: _walkerFor(), windows: windows);
    final result = await scanner.scan(
      libraryId: library.id,
      root: root,
      onProgress: (count) =>
          _notify(l10n.local_scanFound(count), AppNotifyKind.info),
    );
    if (result.items.isEmpty) {
      // 整次失败（桥不可用/根目录没了）与「这个目录里没有媒体」都到这里：
      // 两种情况下都没什么可合并的，直接提示并保留原索引。
      _notify(
        result.warning ?? l10n.local_emptyFolder,
        result.warning == null ? AppNotifyKind.warn : AppNotifyKind.error,
      );
      return null;
    }
    final LocalMediaScanSummary summary;
    try {
      summary = await store.applyScanResult(library.id, result.items);
    } on LocalMediaException catch (error) {
      _notify(error.message, AppNotifyKind.error);
      return null;
    }
    _notify(_summaryMessage(result, summary), AppNotifyKind.success);
    return summary;
  }

  /// 找同组的已有**文件型**库,把这组条目追进去。
  ///
  /// 只认文件型库:目录型库的内容由「那个目录扫出来什么」定义(§8.4 的重新扫描),
  /// 把目录外的文件塞进去会让这份语义变糊。目录外的散集因此会另开一张卡,由用户
  /// 自己「重命名」或(P1)「移动条目」收拾。
  ///
  /// 并入失败(比如库刚好被删了)不吞掉用户的挑选:提示一句后返回 null,
  /// 调用方会改成新建一个库。
  Future<LocalLibrary?> _mergeIntoExisting(LocalLibraryGroup group) async {
    final target = _findMergeTarget(group.key);
    if (target == null) return null;
    try {
      await store.applyScanResult(target.id, group.items);
    } on LocalMediaException catch (error) {
      _notify(error.message, AppNotifyKind.error);
      return null;
    }
    return store.library(target.id) ?? target;
  }

  /// 已有的文件型库里,哪一只装的是同一组东西(按 [groupLocalItemsForLibraries]
  /// 算出来的键比较)。库里的条目现算,所以本次改动之前建的库照样能被认出来。
  LocalLibrary? _findMergeTarget(String key) {
    for (final library in store.libraries) {
      if (library.kind != LocalLibraryKind.file) continue;
      final items = store.items(library.id);
      if (items.isEmpty) continue;
      for (final group in groupLocalItemsForLibraries(items)) {
        if (group.key == key) return library;
      }
    }
    return null;
  }

  /// 移除一个本地库(只删索引,不动用户文件 —— 规格 §5.5/§10)。
  Future<bool> removeLibrary(LocalLibrary library) async {
    try {
      await store.removeLibrary(library.id);
      return true;
    } on LocalMediaException catch (error) {
      _notify(error.message, AppNotifyKind.error);
      return false;
    }
  }

  LocalDirectoryWalker _walkerFor() {
    if (!windows) {
      return androidWalker ?? SafDirectoryWalker(bridge);
    }
    return windowsWalker;
  }

  Future<LocalLibrary?> _create({
    required String name,
    required LocalLibraryKind kind,
    String? path,
    String? treeUri,
    List<LocalMediaItem> items = const [],
  }) async {
    try {
      return await store.addLibrary(
        name: name,
        kind: kind,
        path: path,
        treeUri: treeUri,
        items: items,
      );
    } on LocalMediaException catch (error) {
      // 位置重复不是错误:换个提示语气就行,所以这里只算一次判断。
      final duplicate = error.reason == LocalMediaError.duplicateLocation;
      _notify(
        duplicate ? l10n.local_duplicateLocation : error.message,
        duplicate ? AppNotifyKind.info : AppNotifyKind.error,
      );
      return null;
    }
  }

  /// 把用户挑的一批文件变成条目:解析标题/季集,并只在**名字唯一**时配对字幕。
  ///
  /// 路线 B 没有目录可扫,所以字幕只能来自用户一起挑进来的那些文件;
  /// 同名文件(不同目录各一个 `Show.E01.srt`)不猜,宁可少配一个也不错配。
  List<LocalMediaItem> _itemsFromPicked(List<PickedLocation> picked) {
    final names = [for (final entry in picked) entry.name];
    final now = DateTime.now().millisecondsSinceEpoch;
    final items = <LocalMediaItem>[];
    for (final entry in picked) {
      if (!isPickableLocalMediaName(entry.name)) continue;
      final parsed = parseMediaFileName(entry.name);
      final subtitles = <LocalSubtitle>[];
      for (final subName in subtitlesForVideo(
        videoFileName: entry.name,
        directoryFileNames: names,
      )) {
        final subtitle = _subtitleFor(subName, picked);
        if (subtitle != null) subtitles.add(subtitle);
      }
      final sizeBytes = windows ? _sizeOf(entry.location) : 0;
      final modifiedAt = windows ? _modifiedAtOf(entry.location) : null;
      items.add(
        LocalMediaItem(
          id: '',
          // store 会在 addLibrary 里改成真实库 id。
          libraryId: '',
          title: parsed.title.isEmpty ? entry.name : parsed.title,
          location: entry.location,
          season: parsed.season,
          episode: parsed.episode,
          sizeBytes: sizeBytes,
          modifiedAt: modifiedAt,
          subtitles: subtitles,
          addedAt: now,
        ),
      );
    }
    return items;
  }

  /// 一个候选字幕名 → 字幕条目;**同名文件不止一个就不猜**(宁可少配也不错配)。
  LocalSubtitle? _subtitleFor(String subName, List<PickedLocation> picked) {
    final candidates = [
      for (final candidate in picked)
        if (candidate.name == subName) candidate,
    ];
    if (candidates.length != 1) return null;
    return LocalSubtitle(
      location: candidates.single.location,
      label: subtitleLabelFor(subName),
      language: subtitleLanguageFor(subName),
    );
  }

  int _sizeOf(String location) =>
      _readLocalFile(location, (file) => file.lengthSync()) ?? 0;

  int? _modifiedAtOf(String location) => _readLocalFile(
      location, (file) => file.lastModifiedSync().millisecondsSinceEpoch);

  /// 真去读一个本地文件(Windows 才有真实路径):不存在、读不动都当「没有」,
  /// 绝不向上抛 —— 索引能建起来比读到一个大小更重要。
  T? _readLocalFile<T>(String location, T? Function(File file) read) {
    try {
      final file = File(location);
      return file.existsSync() ? read(file) : null;
    } on Object {
      return null;
    }
  }

  String _summaryMessage(LocalScanResult result, LocalMediaScanSummary summary) {
    final parts = <String>[l10n.local_itemCount(result.items.length)];
    if (result.skipped > 0) parts.add(l10n.local_scanSkipN(result.skipped));
    if (result.truncated) parts.add(l10n.local_scanTooMany(result.items.length));
    if (summary.missing > 0) parts.add(l10n.local_fileMissing);
    return parts.join(' · ');
  }

  /// 失败提示:只说「哪一类错」,**绝不带上路径**(规格 §10)。
  void _reportError(Object error) {
    _notify(l10n.local_error(scrubLocalPath(error.toString())), AppNotifyKind.error);
  }
}

/// 把异常摘要里像路径的部分抹掉(规格 §10:日志与提示不带用户目录)。
@visibleForTesting
String scrubLocalPath(String text) => text
    .replaceAll(RegExp(r'[A-Za-z][A-Za-z0-9+.-]*://[^\s,;)]+'), '<位置>')
    .replaceAll(RegExp(r'[A-Za-z]:\\[^\s,;)]*'), '<路径>')
    .replaceAll(RegExp(r'/(?:[^\s,;:)]+/)+[^\s,;:)]*'), '<路径>');
