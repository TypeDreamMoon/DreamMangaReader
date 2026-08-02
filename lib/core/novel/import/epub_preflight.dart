import 'package:archive/archive.dart';

class EpubArchiveEntry {
  const EpubArchiveEntry({
    required this.relativePath,
    required this.file,
  });

  final String relativePath;
  final ArchiveFile file;
}

class EpubPreflight {
  static const int maxEntries = 20000;
  static const int maxEntrySize = 128 * 1024 * 1024;
  static const int maxTotalSize = 1024 * 1024 * 1024;
  static const int ratioThresholdSize = 1024 * 1024;
  static const int maxCompressionRatio = 200;

  static List<EpubArchiveEntry> validate(Iterable<ArchiveFile> files) {
    final result = <EpubArchiveEntry>[];
    final paths = <String>{};
    var totalSize = 0;

    for (final file in files) {
      if (result.length >= maxEntries) {
        throw const FormatException('EPUB contains too many entries');
      }
      if (file.isSymbolicLink) {
        throw FormatException(
            'EPUB symbolic link is not allowed: ${file.name}');
      }

      final relativePath = normalizeRelativePath(file.name);
      if (!paths.add(relativePath.toLowerCase())) {
        throw FormatException('EPUB contains a duplicate path: $relativePath');
      }
      if (file.size < 0 || file.size > maxEntrySize) {
        throw FormatException('EPUB entry is too large: $relativePath');
      }

      totalSize += file.size;
      if (totalSize > maxTotalSize) {
        throw const FormatException('EPUB uncompressed size is too large');
      }

      if (file.isFile && file.size > ratioThresholdSize) {
        final compressedSize = file.rawContent?.length ?? file.size;
        if (compressedSize <= 0 ||
            file.size > compressedSize * maxCompressionRatio) {
          throw FormatException(
            'EPUB entry compression ratio is too high: $relativePath',
          );
        }
      }
      result.add(EpubArchiveEntry(relativePath: relativePath, file: file));
    }

    return List.unmodifiable(result);
  }

  static String normalizeRelativePath(String source) {
    final value = source.replaceAll('\\', '/');
    if (value.isEmpty || value.contains('\u0000')) {
      throw const FormatException('EPUB contains an invalid empty path');
    }
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value)) {
      throw FormatException('EPUB contains an absolute path: $source');
    }

    final parts = <String>[];
    for (final part in value.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isEmpty) {
          throw FormatException('EPUB path escapes the import root: $source');
        }
        parts.removeLast();
        continue;
      }
      _validatePortableSegment(part, source);
      parts.add(part);
    }
    if (parts.isEmpty) {
      throw FormatException('EPUB contains an invalid path: $source');
    }
    return parts.join('/');
  }

  static String resolveRelativePath(String baseDirectory, String source) {
    final value = source.replaceAll('\\', '/');
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value)) {
      throw FormatException('EPUB contains an absolute path: $source');
    }
    final base = baseDirectory.trim();
    return normalizeRelativePath(base.isEmpty ? value : '$base/$value');
  }
}

void _validatePortableSegment(String part, String source) {
  if (part.endsWith('.') ||
      part.endsWith(' ') ||
      RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(part)) {
    throw FormatException('EPUB path is not portable: $source');
  }
  final deviceName = part.split('.').first.toUpperCase();
  if (deviceName == 'CON' ||
      deviceName == 'PRN' ||
      deviceName == 'AUX' ||
      deviceName == 'NUL' ||
      RegExp(r'^(COM|LPT)[1-9]$').hasMatch(deviceName)) {
    throw FormatException('EPUB path uses a reserved device name: $source');
  }
}
