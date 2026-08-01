import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/novel_library_store.dart';
import '../../core/novel/import/epub_novel_importer.dart';
import '../../core/novel/import/txt_novel_importer.dart';
import '../../core/novel/models.dart';

typedef NovelFilePicker = Future<File?> Function();
typedef TxtPreviewLoader = Future<TxtNovelImportPreview> Function(
  File file, {
  String? forcedEncoding,
});
typedef TxtPreviewInstaller = Future<Directory> Function(
  TxtNovelImportPreview preview,
);
typedef EpubPreviewLoader = Future<EpubNovelImportPreview> Function(File file);
typedef EpubPreviewInstaller = Future<ImportedEpubNovel> Function(
  EpubNovelImportPreview preview,
);

class NovelImportServices {
  const NovelImportServices({
    required this.pickFile,
    required this.previewTxt,
    required this.importTxt,
    required this.previewEpub,
    required this.importEpub,
  });

  factory NovelImportServices.defaults() {
    final txt = TxtNovelImporter();
    final epub = EpubNovelImporter();
    return NovelImportServices(
      pickFile: _pickNovelFile,
      previewTxt: txt.preview,
      importTxt: txt.importPreview,
      previewEpub: epub.preview,
      importEpub: epub.importPreview,
    );
  }

  final NovelFilePicker pickFile;
  final TxtPreviewLoader previewTxt;
  final TxtPreviewInstaller importTxt;
  final EpubPreviewLoader previewEpub;
  final EpubPreviewInstaller importEpub;
}

class NovelImportButton extends StatelessWidget {
  const NovelImportButton({
    super.key,
    this.services,
    this.compact = false,
  });

  final NovelImportServices? services;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(
        tooltip: '导入本地小说',
        onPressed: () => _startImport(context),
        icon: const Icon(Icons.file_open_rounded),
      );
    }
    return FilledButton.icon(
      onPressed: () => _startImport(context),
      icon: const Icon(Icons.file_open_rounded),
      label: const Text('导入本地小说'),
    );
  }

  Future<void> _startImport(BuildContext context) async {
    final activeServices = services ?? NovelImportServices.defaults();
    final store = NovelLibraryScope.read(context);
    final file = await activeServices.pickFile();
    if (file == null || !context.mounted) return;
    final extension = file.path.split('.').last.toLowerCase();
    if (extension != 'txt' && extension != 'epub') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('只支持 TXT 和 EPUB 文件')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _NovelImportSheet(
        file: file,
        extension: extension,
        services: activeServices,
        store: store,
      ),
    );
  }
}

class _NovelImportSheet extends StatefulWidget {
  const _NovelImportSheet({
    required this.file,
    required this.extension,
    required this.services,
    required this.store,
  });

  final File file;
  final String extension;
  final NovelImportServices services;
  final NovelLibraryStore store;

  @override
  State<_NovelImportSheet> createState() => _NovelImportSheetState();
}

class _NovelImportSheetState extends State<_NovelImportSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _author = TextEditingController();
  ImportedNovelPreview? _preview;
  Object? _error;
  bool _loading = true;
  bool _installing = false;
  int _generation = 0;

  TxtNovelImportPreview? get _txtPreview =>
      _preview is TxtNovelImportPreview ? _preview! as TxtNovelImportPreview : null;
  EpubNovelImportPreview? get _epubPreview => _preview is EpubNovelImportPreview
      ? _preview! as EpubNovelImportPreview
      : null;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview({String? forcedEncoding}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = widget.extension == 'txt'
          ? await widget.services.previewTxt(
              widget.file,
              forcedEncoding: forcedEncoding,
            )
          : await widget.services.previewEpub(widget.file);
      if (!mounted || generation != _generation) return;
      setState(() {
        _preview = preview;
        _title.text = preview.title;
        _author.text = preview.authors.join('、');
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _confirm() async {
    final preview = _preview;
    final title = _title.text.trim();
    if (preview == null || title.isEmpty || _installing) return;
    final authors = _author.text
        .split(RegExp(r'[,，、;；]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    setState(() => _installing = true);
    try {
      late final Directory directory;
      late final NovelOrigin origin;
      if (_txtPreview case final txt?) {
        final edited = TxtNovelImportPreview(
          sha256: txt.sha256,
          title: title,
          authors: authors,
          chapters: txt.chapters,
          encoding: txt.encoding,
          normalizedText: txt.normalizedText,
          parsed: txt.parsed,
        );
        directory = await widget.services.importTxt(edited);
        origin = NovelOrigin.localTxt;
      } else if (_epubPreview case final epub?) {
        final edited = EpubNovelImportPreview(
          sha256: epub.sha256,
          title: title,
          authors: authors,
          chapters: epub.chapters,
          hasCover: epub.hasCover,
          language: epub.language,
          originalBytes: epub.originalBytes,
          resources: epub.resources,
          chapterResources: epub.chapterResources,
        );
        directory = (await widget.services.importEpub(edited)).directory;
        origin = NovelOrigin.localEpub;
      } else {
        throw StateError('未知的小说导入格式');
      }
      if (!mounted) return;
      widget.store.addLocal(NovelLibraryEntry.local(
        sha256: preview.sha256,
        title: title,
        authors: authors,
        privatePath: directory.path,
        origin: origin,
      ));
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: _loading
              ? const SizedBox(
                  height: 240,
                  child: Center(child: CircularProgressIndicator()),
                )
              : _error != null && _preview == null
                  ? _errorView()
                  : _previewView(),
        ),
      ),
    );
  }

  Widget _errorView() {
    return SizedBox(
      height: 240,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline_rounded, size: 40),
          const SizedBox(height: 12),
          Text('文件解析失败\n$_error', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loadPreview,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _previewView() {
    final preview = _preview!;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '导入预览',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('novel-import-title'),
            controller: _title,
            enabled: !_installing,
            decoration: const InputDecoration(labelText: '书名'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('novel-import-author'),
            controller: _author,
            enabled: !_installing,
            decoration: const InputDecoration(labelText: '作者'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.format_list_numbered_rounded, size: 18),
              const SizedBox(width: 8),
              Text('${preview.chapters.length} 章'),
              if (preview.origin == NovelOrigin.localEpub) ...[
                const SizedBox(width: 16),
                const Text('EPUB'),
              ],
            ],
          ),
          if (_txtPreview case final txt?) ...[
            const SizedBox(height: 16),
            Text('当前编码：${_encodingLabel(txt.encoding)}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _encodingChip('UTF-8', 'utf-8', txt.encoding),
                _encodingChip('GB18030 / GBK', 'gb18030', txt.encoding),
                _encodingChip('Big5', 'big5', txt.encoding),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              '操作失败：$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _installing ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _installing ? null : _confirm,
                icon: _installing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('确认导入'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _encodingChip(String label, String value, String current) {
    return ChoiceChip(
      label: Text(label),
      selected: _canonicalEncoding(current) == value,
      onSelected: _installing ? null : (_) => _loadPreview(forcedEncoding: value),
    );
  }

  @override
  void dispose() {
    _generation++;
    _title.dispose();
    _author.dispose();
    super.dispose();
  }
}

Future<File?> _pickNovelFile() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['txt', 'epub'],
    allowMultiple: false,
    withData: false,
  );
  final path = result == null || result.files.isEmpty
      ? null
      : result.files.single.path;
  return path == null ? null : File(path);
}

String _canonicalEncoding(String value) {
  final normalized = value.toLowerCase().replaceAll('_', '-');
  if (normalized == 'gbk' || normalized == 'cp936') return 'gb18030';
  if (normalized == 'utf8') return 'utf-8';
  if (normalized == 'big-5') return 'big5';
  return normalized;
}

String _encodingLabel(String value) {
  switch (_canonicalEncoding(value)) {
    case 'utf-8':
      return 'UTF-8';
    case 'utf-16le':
      return 'UTF-16 LE';
    case 'utf-16be':
      return 'UTF-16 BE';
    case 'gb18030':
      return 'GB18030 / GBK';
    case 'big5':
      return 'Big5';
    default:
      return value.toUpperCase();
  }
}
