import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/library_store.dart' show LibraryStore;
import '../../app/novel_library_store.dart';
import '../../app/theme/app_colors.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/novel/models.dart';
import '../../core/source/source_registry.dart';
import '../../ui/ui.dart';
import '../common/animations.dart';
import 'novel_cover.dart';
import 'novel_detail_page.dart';
import 'novel_import_sheet.dart';
import 'novel_reader_page.dart';

typedef NovelSupportDirectory = Future<Directory> Function();

class LocalNovelBook {
  LocalNovelBook._({
    required this.directory,
    required this.novel,
    required this.origin,
    required this.chapters,
    required Map<String, Map<String, dynamic>> chapterData,
  }) : _chapterData = chapterData;

  final Directory directory;
  final Novel novel;
  final NovelOrigin origin;
  final List<NovelChapter> chapters;
  final Map<String, Map<String, dynamic>> _chapterData;

  static Future<LocalNovelBook> open(
    Directory directory, {
    String untitledTitle = 'Untitled novel',
  }) async {
    final indexFile = File(_join(directory.path, 'index.json'));
    final decoded = jsonDecode(await indexFile.readAsString(encoding: utf8));
    if (decoded is! Map) {
      throw const FormatException('小说索引格式无效');
    }
    final index = decoded.cast<String, dynamic>();
    final origin = switch (index['origin']) {
      'localTxt' => NovelOrigin.localTxt,
      'localEpub' => NovelOrigin.localEpub,
      _ => throw const FormatException('小说索引缺少有效格式'),
    };
    final chapterData = <String, Map<String, dynamic>>{};
    final chapters = <NovelChapter>[];
    final rawChapters = index['chapters'];
    if (rawChapters is! List) {
      throw const FormatException('小说索引缺少章节目录');
    }
    for (final value in rawChapters) {
      if (value is! Map) continue;
      final data = value.cast<String, dynamic>();
      final id = data['id'] as String?;
      final title = data['title'] as String?;
      if (id == null || id.isEmpty || title == null || title.isEmpty) continue;
      chapterData[id] = data;
      chapters.add(NovelChapter(
        id: id,
        title: title,
        number: (data['number'] as num?)?.toDouble(),
        volumeId: data['volumeId'] as String?,
        volumeTitle: data['volumeTitle'] as String?,
        epubAnchor: data['anchor'] as String?,
      ));
    }
    if (chapters.isEmpty) {
      throw const FormatException('小说没有可读章节');
    }
    final title = (index['title'] as String? ?? '').trim();
    return LocalNovelBook._(
      directory: directory,
      origin: origin,
      novel: Novel(
        id: index['sha256'] as String? ?? directory.uri.pathSegments.last,
        title: title.isEmpty ? untitledTitle : title,
        authors: List<String>.unmodifiable(
          (index['authors'] as List? ?? const [])
              .map((value) => value.toString()),
        ),
      ),
      chapters: List.unmodifiable(chapters),
      chapterData: Map.unmodifiable(chapterData),
    );
  }

  Future<NovelDocument> loadDocument(NovelChapter chapter) async {
    final data = _chapterData[chapter.id];
    if (data == null) {
      throw ArgumentError.value(chapter.id, 'chapter', '章节不存在');
    }
    if (origin == NovelOrigin.localTxt) {
      final start = (data['contentOffset'] as num?)?.toInt();
      final end = (data['endOffset'] as num?)?.toInt();
      if (start == null || end == null || start < 0 || end <= start) {
        throw const FormatException('TXT 章节偏移无效');
      }
      final file = File(_join(directory.path, 'content.txt'));
      final handle = await file.open();
      try {
        final length = await handle.length();
        if (end > length) throw const FormatException('TXT 章节超出正文范围');
        await handle.setPosition(start);
        final bytes = await handle.read(end - start);
        return NovelDocument(
          format: NovelDocumentFormat.text,
          content: utf8.decode(bytes),
        );
      } finally {
        await handle.close();
      }
    }

    final resource = data['resource'] as String?;
    if (resource == null || resource.isEmpty) {
      throw const FormatException('EPUB 章节资源缺失');
    }
    final root = Directory(_join(directory.path, 'resources'));
    final file = await _safeExistingFile(root, resource);
    return NovelDocument(
      format: NovelDocumentFormat.html,
      content: await file.readAsString(encoding: utf8),
      baseUrl: file.uri.toString(),
    );
  }
}

class NovelLibraryView extends StatefulWidget {
  const NovelLibraryView({
    super.key,
    this.importServices,
    this.searchVisible = false,
  });

  final NovelImportServices? importServices;

  /// 搜索框是否展开。开关在书架页标题栏上(与漫画书架同一个放大镜),收起时清筛选词。
  final bool searchVisible;

  @override
  State<NovelLibraryView> createState() => _NovelLibraryViewState();
}

class _NovelLibraryViewState extends State<NovelLibraryView> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void didUpdateWidget(covariant NovelLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 收起搜索框 = 退出筛选态(漫画书架同语义)。已在重建途中,不必再 setState。
    if (oldWidget.searchVisible && !widget.searchVisible) {
      _search.clear();
      _query = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = NovelLibraryScope.of(context);
    final entries = store.entries.where((entry) {
      final query = _query.toLowerCase();
      return query.isEmpty ||
          entry.title.toLowerCase().contains(query) ||
          entry.authors.any((author) => author.toLowerCase().contains(query));
    }).toList(growable: false)
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final continued = <NovelLibraryEntry>[];
    for (final item in store.history) {
      final entry = store.entryFor(item.key);
      if (entry != null && entries.contains(entry)) continued.add(entry);
    }

    return Column(
      children: [
        // 搜索框展开/收起用高度动画,避免书架内容硬跳(与漫画书架同款)。
        AnimatedSize(
          duration: LibraryStore.animationsEnabled
              ? const Duration(milliseconds: 220)
              : Duration.zero,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: widget.searchVisible
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: AppSearchField(
                    controller: _search,
                    autofocus: true,
                    hint: context.l10n.novel_librarySearchHint,
                    onChanged: (value) => setState(() => _query = value.trim()),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        Expanded(
          child: entries.isEmpty
              ? _emptyState()
              : AppScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    if (continued.isNotEmpty) ...[
                      _sectionTitle(
                        context.l10n.novel_continueReading,
                        continued.length,
                      ),
                      for (final entry in continued)
                        _entryTile(context, p, store, entry,
                            tagPrefix: 'ncont'),
                      const SizedBox(height: 14),
                    ],
                    _sectionTitle(
                      context.l10n.novel_libraryTitle,
                      entries.length,
                    ),
                    for (final entry in entries)
                      _entryTile(context, p, store, entry, tagPrefix: 'nshelf'),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    // 空书架的正经出路就是导入,把导入按钮当 CTA 摆在空态里(标题栏那颗只是快捷入口)。
    return EmptyState(
      icon: Icons.menu_book_rounded,
      iconSize: 46,
      title: _query.isEmpty
          ? context.l10n.novel_libraryEmpty
          : context.l10n.novel_libraryNoMatch,
      action: _query.isEmpty
          ? NovelImportButton(services: widget.importServices)
          : null,
    );
  }

  Widget _sectionTitle(String title, int count) {
    return AppSectionHeading(
      context.l10n.novel_sectionCount(title, count),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 14),
    );
  }

  /// 书架行。版式跟漫画书架的 `coverListTile` 对齐(56 宽封面 + palette 面/描边 +
  /// [Pressable] 按压反馈),不用 Material/InkWell 那套默认色 —— 三主题下会跑色。
  Widget _entryTile(
    BuildContext context,
    AppPalette p,
    NovelLibraryStore store,
    NovelLibraryEntry entry, {
    required String tagPrefix,
  }) {
    final progress = store.progressFor(entry.key);
    // 只有远端条目会打开详情页(本地书直接进阅读器),本地书不给 tag。
    // 前缀区分区块:同一本书会同时出现在「继续阅读」和书架列表里,
    // 共用 tag 会让 Hero 抛「同屏多个相同 tag」。
    final heroTag = entry.isLocal ? null : '$tagPrefix:${entry.key}';
    final novel = Novel(
      id: entry.novelId ?? entry.fingerprint ?? entry.key,
      title: entry.title,
      cover: entry.cover,
      authors: entry.authors,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: entry.available
            ? () => openNovelLibraryEntry(context, entry, heroTag: heroTag)
            : null,
        hoverElevate: true,
        child: Container(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(context.radius),
            border: Border.all(color: p.line),
          ),
          padding: const EdgeInsets.all(9),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: NovelCover(
                  novel: novel,
                  radius: 8,
                  heroTag: heroTag,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (entry.authors.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        entry.authors.join('、'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textMuted, fontSize: 11.5),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      !entry.available
                          ? context.l10n.novel_fileMissing
                          : progress != null
                              ? context.l10n.novel_readTo(progress.chapterId)
                              : entry.isLocal
                                  ? context.l10n.novel_localFormat(
                                      entry.origin == NovelOrigin.localTxt
                                          ? 'TXT'
                                          : 'EPUB',
                                    )
                                  : context.l10n.novel_online,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: !entry.available
                            ? p.statusFail
                            : progress != null
                                ? p.accentSoft
                                : p.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (!entry.available)
                NovelImportButton(
                  services: widget.importServices,
                  compact: true,
                ),
              IconButton(
                tooltip: entry.isLocal
                    ? context.l10n.novel_deleteLocal
                    : context.l10n.novel_removeFavorite,
                onPressed: () => entry.isLocal
                    ? _confirmDelete(context, store, entry)
                    : store.toggleRemoteFavorite(entry),
                icon: Icon(
                  entry.isLocal
                      ? Icons.delete_outline_rounded
                      : Icons.favorite_border_rounded,
                  color: p.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    NovelLibraryStore store,
    NovelLibraryEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.novel_deleteLocalTitle),
        content: Text(
          entry.available
              ? dialogContext.l10n.novel_deleteLocalConfirm(entry.title)
              : dialogContext.l10n.novel_deleteMissingConfirm(entry.title),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final path = entry.privatePath;
      if (entry.available && path != null) {
        await deleteLocalNovelDirectory(path);
      }
      store.removeLocal(entry.key, removeHistory: true);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.novel_deleteFailed('$error'))),
      );
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }
}

Future<void> openNovelLibraryEntry(
  BuildContext context,
  NovelLibraryEntry entry, {
  Object? heroTag,
}) async {
  if (entry.isLocal) {
    final path = entry.privatePath;
    if (path == null) return;
    try {
      final book = await LocalNovelBook.open(
        Directory(path),
        untitledTitle: context.l10n.novel_unnamed,
      );
      if (!context.mounted) return;
      final saved = NovelLibraryScope.read(context).progressFor(entry.key);
      final initialIndex = saved == null
          ? 0
          : book.chapters.indexWhere((chapter) => chapter.id == saved.chapterId);
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => NovelReaderPage(
          novel: book.novel,
          chapters: book.chapters,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
          libraryKey: entry.key,
          loadDocument: book.loadDocument,
        ),
      ));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.novel_openFailed('$error'))),
      );
    }
    return;
  }

  SourceMeta? meta;
  for (final source in registeredSources) {
    if (source.id == entry.sourceId && source.isNovel) {
      meta = source;
      break;
    }
  }
  if (meta == null || entry.novelId == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.novel_sourceUnavailable)),
    );
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => NovelDetailPage(
      meta: meta!,
      heroTag: heroTag,
      novel: Novel(
        id: entry.novelId!,
        title: entry.title,
        cover: entry.cover,
        authors: entry.authors,
      ),
    ),
  ));
}

Future<void> deleteLocalNovelDirectory(
  String targetPath, {
  NovelSupportDirectory? applicationSupportDirectory,
}) async {
  final support = await (applicationSupportDirectory ?? getApplicationSupportDirectory)();
  final root = Directory(_join(_join(support.path, 'novels'), 'local'));
  final target = Directory(targetPath);
  final rootPath = await root.resolveSymbolicLinks();
  final targetResolved = await target.resolveSymbolicLinks();
  final prefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  if (targetResolved == rootPath || !targetResolved.startsWith(prefix)) {
    throw FileSystemException('拒绝删除 App 小说目录之外的路径', targetPath);
  }
  await Directory(targetResolved).delete(recursive: true);
}

Future<File> _safeExistingFile(Directory root, String relativePath) async {
  final normalized = relativePath.replaceAll('\\', '/');
  if (normalized.startsWith('/') || normalized.split('/').contains('..')) {
    throw FormatException('EPUB 资源路径无效：$relativePath');
  }
  final rootPath = await root.resolveSymbolicLinks();
  final candidate = File(_join(root.path, normalized.replaceAll('/', Platform.pathSeparator)));
  final candidatePath = await candidate.resolveSymbolicLinks();
  final prefix = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  if (!candidatePath.startsWith(prefix)) {
    throw FormatException('EPUB 资源越过私有目录：$relativePath');
  }
  return File(candidatePath);
}

String _join(String parent, String child) {
  if (parent.endsWith(Platform.pathSeparator)) return '$parent$child';
  return '$parent${Platform.pathSeparator}$child';
}
