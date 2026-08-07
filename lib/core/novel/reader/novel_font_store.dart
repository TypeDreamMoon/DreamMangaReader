import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef NovelFontSupportDirectory = Future<Directory> Function();
typedef NovelFontAssetLoader = Future<List<int>> Function(String assetPath);

abstract final class NovelFontIds {
  static const notoSerifSc = 'builtin:noto-serif-sc';
  static const lxgwWenKai = 'builtin:lxgw-wenkai';
  static const importedPrefix = 'imported:';
}

String normalizeNovelFontId(Object? value) {
  final raw = value is String ? value.trim() : '';
  if (raw == NovelFontIds.notoSerifSc || raw == NovelFontIds.lxgwWenKai) {
    return raw;
  }
  final lower = raw.toLowerCase();
  if (lower == 'lxgw wenkai' || lower == 'lxgwwenkai') {
    return NovelFontIds.lxgwWenKai;
  }
  if (RegExp(r'^imported:[a-f0-9]{64}$').hasMatch(lower)) return lower;
  return NovelFontIds.notoSerifSc;
}

enum NovelFontImportError {
  unsupportedExtension,
  invalidStructure,
  unreadableFile,
  fileTooLarge,
}

class NovelFontImportException implements Exception {
  const NovelFontImportException(this.code, this.message);

  final NovelFontImportError code;
  final String message;

  @override
  String toString() => message;
}

class NovelFontRecord {
  const NovelFontRecord({
    required this.id,
    required this.displayName,
    required this.cssFamily,
    required this.file,
  });

  final String id;
  final String displayName;
  final String cssFamily;
  final File file;
}

class NovelBuiltinFont {
  const NovelBuiltinFont({
    required this.id,
    required this.displayName,
    required this.cssFamily,
    required this.assetPath,
    required this.fileName,
    required this.sha256,
  });

  final String id;
  final String displayName;
  final String cssFamily;
  final String assetPath;
  final String fileName;
  final String sha256;
}

const novelBuiltinFonts = <NovelBuiltinFont>[
  NovelBuiltinFont(
    id: NovelFontIds.notoSerifSc,
    displayName: 'Noto Serif SC',
    cssFamily: 'DMR Noto Serif SC',
    assetPath: 'assets/fonts/NotoSerifSC-Regular.otf',
    fileName: 'NotoSerifSC-Regular.otf',
    sha256: '2a2eae2628df83556c54018c41e20fa532c1b862c5256ae8b3f23feb918d12ca',
  ),
  NovelBuiltinFont(
    id: NovelFontIds.lxgwWenKai,
    displayName: '霞鹜文楷',
    cssFamily: 'DMR LXGW WenKai',
    assetPath: 'assets/fonts/LXGWWenKai-Regular.ttf',
    fileName: 'LXGWWenKai-Regular.ttf',
    sha256: '39ad71264b588165b469e35e6afb162a378dacd1f95348160240ba9038ac3009',
  ),
];

class NovelFontStore {
  static const maxImportBytes = 64 * 1024 * 1024;

  NovelFontStore({
    NovelFontSupportDirectory? applicationSupportDirectory,
    NovelFontAssetLoader? loadAsset,
  })  : _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory,
        _loadAsset = loadAsset ?? _loadBundledFont;

  final NovelFontSupportDirectory _applicationSupportDirectory;
  final NovelFontAssetLoader _loadAsset;

  Future<NovelFontRecord> importFont(File source) async {
    final sourceName = _basename(source.path);
    final extension = _extension(sourceName).toLowerCase();
    if (extension != '.ttf' && extension != '.otf') {
      throw const NovelFontImportException(
        NovelFontImportError.unsupportedExtension,
        'Only TTF and OTF fonts are supported.',
      );
    }

    late final int sourceLength;
    try {
      sourceLength = await source.length();
    } on FileSystemException {
      throw const NovelFontImportException(
        NovelFontImportError.unreadableFile,
        'The font file could not be read.',
      );
    }
    if (sourceLength > maxImportBytes) {
      throw const NovelFontImportException(
        NovelFontImportError.fileTooLarge,
        'The font file is larger than 64 MiB.',
      );
    }

    late final List<int> bytes;
    try {
      bytes = await source.readAsBytes();
    } on FileSystemException {
      throw const NovelFontImportException(
        NovelFontImportError.unreadableFile,
        'The font file could not be read.',
      );
    }
    if (!_hasValidSfntStructure(bytes, extension)) {
      throw const NovelFontImportException(
        NovelFontImportError.invalidStructure,
        'The font file is truncated or malformed.',
      );
    }

    final digest = sha256.convert(bytes).toString();
    final directory = await _importDirectory(create: true);
    final existing = await _findImportedByHash(directory, digest);
    if (existing != null) return existing;

    final displayName = _sanitizeName(_stem(sourceName));
    final destination = File(
      '${directory.path}${Platform.pathSeparator}'
      '${digest}_$displayName$extension',
    );
    await _writeAtomically(destination, bytes);
    return NovelFontRecord(
      id: '${NovelFontIds.importedPrefix}$digest',
      displayName: displayName,
      cssFamily: 'DMR Imported ${digest.substring(0, 12)}',
      file: destination,
    );
  }

  Future<NovelFontRecord> resolveForUse(String id) async {
    final normalized = normalizeNovelFontId(id);
    final resolved = await resolveFont(normalized);
    if (resolved != null) return resolved;
    return _materializeBuiltin(novelBuiltinFonts.first);
  }

  Future<List<NovelFontRecord>> listImportedFonts() async {
    final directory = await _importDirectory(create: false);
    if (!await directory.exists()) return const [];
    final records = <NovelFontRecord>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final record = await _validatedImportedRecord(entity);
      if (record != null) records.add(record);
    }
    records.sort((a, b) => a.displayName.compareTo(b.displayName));
    return List.unmodifiable(records);
  }

  Future<NovelFontRecord?> resolveFont(String id) async {
    final normalized = normalizeNovelFontId(id);
    if (!normalized.startsWith(NovelFontIds.importedPrefix)) {
      final definition = novelBuiltinFonts.firstWhere(
        (font) => font.id == normalized,
        orElse: () => novelBuiltinFonts.first,
      );
      return _materializeBuiltin(definition);
    }
    final digest = normalized.substring(NovelFontIds.importedPrefix.length);
    final directory = await _importDirectory(create: false);
    if (!await directory.exists()) return null;
    return _findImportedByHash(directory, digest);
  }

  Future<String> deleteFont(String id, {required String selectedId}) async {
    final normalizedId = normalizeNovelFontId(id);
    if (!normalizedId.startsWith(NovelFontIds.importedPrefix)) {
      return normalizeNovelFontId(selectedId);
    }
    final record = await resolveFont(id);
    if (record != null && await record.file.exists()) {
      await record.file.delete();
    }
    return normalizeNovelFontId(selectedId) == normalizeNovelFontId(id)
        ? NovelFontIds.notoSerifSc
        : normalizeNovelFontId(selectedId);
  }

  Future<Directory> _importDirectory({required bool create}) async {
    final support = await _applicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}novel_fonts'
      '${Platform.pathSeparator}imported',
    );
    if (create) await directory.create(recursive: true);
    return directory;
  }

  Future<NovelFontRecord> _materializeBuiltin(
    NovelBuiltinFont definition,
  ) async {
    final support = await _applicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}novel_fonts'
      '${Platform.pathSeparator}builtin',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${definition.fileName}',
    );
    if (!await _matchesBuiltin(file, definition)) {
      final bytes = await _loadAsset(definition.assetPath);
      if (sha256.convert(bytes).toString() != definition.sha256 ||
          !_hasValidSfntStructure(bytes, _extension(definition.fileName))) {
        throw const NovelFontImportException(
          NovelFontImportError.invalidStructure,
          'The bundled font is truncated or malformed.',
        );
      }
      await _writeAtomically(file, bytes);
    }
    final record = NovelFontRecord(
      id: definition.id,
      displayName: definition.displayName,
      cssFamily: definition.cssFamily,
      file: file,
    );
    return record;
  }
}

Future<List<int>> _loadBundledFont(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

String buildNovelFontFaceCss(NovelFontRecord font) {
  final format = _extension(font.file.path).toLowerCase() == '.otf'
      ? 'opentype'
      : 'truetype';
  return '@font-face{font-family:"${font.cssFamily}";'
      'src:url("${font.file.uri}") format("$format");'
      'font-style:normal;font-weight:400;font-display:block;}';
}

bool _hasValidSfntStructure(List<int> bytes, String extension) {
  if (bytes.length < 28) return false;
  final data = ByteData.sublistView(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );
  final signature = data.getUint32(0, Endian.big);
  final signatureMatches = extension == '.otf'
      ? signature == 0x4f54544f
      : signature == 0x00010000 ||
          signature == 0x74727565 ||
          signature == 0x74797031;
  if (!signatureMatches) return false;
  final tableCount = data.getUint16(4, Endian.big);
  if (tableCount == 0 || tableCount > 4096) return false;
  final directoryEnd = 12 + tableCount * 16;
  if (directoryEnd > bytes.length) return false;
  final tags = <String>{};
  final ranges = <(int, int)>[];
  for (var index = 0; index < tableCount; index++) {
    final entry = 12 + index * 16;
    final tag = String.fromCharCodes(bytes.sublist(entry, entry + 4));
    if (!tags.add(tag)) return false;
    final offset = data.getUint32(entry + 8, Endian.big);
    final length = data.getUint32(entry + 12, Endian.big);
    if (length == 0 ||
        offset < directoryEnd ||
        offset > bytes.length ||
        length > bytes.length - offset) {
      return false;
    }
    ranges.add((offset, offset + length));
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  for (var index = 1; index < ranges.length; index++) {
    if (ranges[index].$1 < ranges[index - 1].$2) return false;
  }
  const required = {
    'OS/2',
    'cmap',
    'head',
    'hhea',
    'hmtx',
    'maxp',
    'name',
    'post',
  };
  if (!tags.containsAll(required)) return false;
  return extension == '.otf'
      ? tags.contains('CFF ') || tags.contains('CFF2')
      : tags.contains('glyf') && tags.contains('loca');
}

Future<NovelFontRecord?> _findImportedByHash(
  Directory directory,
  String digest,
) async {
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = _basename(entity.path);
    if (!name.startsWith('${digest}_')) continue;
    final record = await _validatedImportedRecord(entity);
    if (record != null &&
        record.id == '${NovelFontIds.importedPrefix}$digest') {
      return record;
    }
    try {
      await entity.delete();
    } on FileSystemException {
      // A corrupt file that cannot be removed is ignored rather than reused.
    }
  }
  return null;
}

Future<NovelFontRecord?> _validatedImportedRecord(File file) async {
  final record = _recordForFile(file);
  if (record == null) return null;
  try {
    final length = await file.length();
    if (length > NovelFontStore.maxImportBytes) return null;
    final bytes = await file.readAsBytes();
    final expected = record.id.substring(NovelFontIds.importedPrefix.length);
    if (sha256.convert(bytes).toString() != expected ||
        !_hasValidSfntStructure(bytes, _extension(file.path))) {
      return null;
    }
    return record;
  } on FileSystemException {
    return null;
  }
}

Future<bool> _matchesBuiltin(
  File file,
  NovelBuiltinFont definition,
) async {
  if (!await file.exists()) return false;
  try {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString() == definition.sha256 &&
        _hasValidSfntStructure(bytes, _extension(definition.fileName));
  } on FileSystemException {
    return false;
  }
}

Future<void> _writeAtomically(File destination, List<int> bytes) async {
  final temporary = File(
    '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.part',
  );
  final backup = File('${temporary.path}.bak');
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (await destination.exists()) await destination.rename(backup.path);
    try {
      await temporary.rename(destination.path);
    } catch (_) {
      if (await backup.exists()) await backup.rename(destination.path);
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

NovelFontRecord? _recordForFile(File file) {
  final name = _basename(file.path);
  final match = RegExp(r'^([a-f0-9]{64})_(.+)\.(ttf|otf)$').firstMatch(name);
  if (match == null) return null;
  return NovelFontRecord(
    id: '${NovelFontIds.importedPrefix}${match.group(1)}',
    displayName: match.group(2)!,
    cssFamily: 'DMR Imported ${match.group(1)!.substring(0, 12)}',
    file: file,
  );
}

String _sanitizeName(String value) {
  final sanitized = value
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9_\-\u3400-\u9fff]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (sanitized.isEmpty) return 'ImportedFont';
  return sanitized.length <= 64 ? sanitized : sanitized.substring(0, 64);
}

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot);
}

String _stem(String name) {
  final extension = _extension(name);
  return extension.isEmpty
      ? name
      : name.substring(0, name.length - extension.length);
}
