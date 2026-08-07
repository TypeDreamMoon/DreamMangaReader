import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

typedef NovelBackgroundSupportDirectory = Future<Directory> Function();

abstract final class NovelBackgroundIds {
  static const importedPrefix = 'imported:';
  static const paperPrefix = 'builtin:paper-';
}

enum NovelBackgroundError { unreadableFile, invalidImage, imageTooLarge }

class NovelBackgroundException implements Exception {
  const NovelBackgroundException(this.code, this.message);

  final NovelBackgroundError code;
  final String message;

  @override
  String toString() => message;
}

class NovelBackgroundRecord {
  const NovelBackgroundRecord({
    required this.id,
    required this.file,
    required this.width,
    required this.height,
    this.averageArgb = 0xffffffff,
  });

  final String id;
  final File file;
  final int width;
  final int height;
  final int averageArgb;
}

class NovelBackgroundStore {
  static const maxImportBytes = 32 * 1024 * 1024;

  NovelBackgroundStore({
    NovelBackgroundSupportDirectory? applicationSupportDirectory,
  }) : _applicationSupportDirectory =
            applicationSupportDirectory ?? getApplicationSupportDirectory;

  final NovelBackgroundSupportDirectory _applicationSupportDirectory;

  Future<NovelBackgroundRecord> importImage(File source) async {
    late final int sourceLength;
    try {
      sourceLength = await source.length();
    } on FileSystemException {
      throw const NovelBackgroundException(
        NovelBackgroundError.unreadableFile,
        'The background image could not be read.',
      );
    }
    if (sourceLength > maxImportBytes) {
      throw const NovelBackgroundException(
        NovelBackgroundError.imageTooLarge,
        'The background image is larger than 32 MiB.',
      );
    }
    late final List<int> bytes;
    try {
      bytes = await source.readAsBytes();
    } on FileSystemException {
      throw const NovelBackgroundException(
        NovelBackgroundError.unreadableFile,
        'The background image could not be read.',
      );
    }
    final decoded = _decodeValidated(bytes);
    final normalizedBytes = img.encodePng(decoded);
    final digest = sha256.convert(normalizedBytes).toString();
    final directory = await _directory('imported', create: true);
    final destination = File(
      '${directory.path}${Platform.pathSeparator}$digest.png',
    );
    if (await _decodeImportedFile(destination, digest) == null) {
      await _writeAtomically(destination, normalizedBytes);
    }
    return NovelBackgroundRecord(
      id: '${NovelBackgroundIds.importedPrefix}$digest',
      file: destination,
      width: decoded.width,
      height: decoded.height,
      averageArgb: _averageArgb(decoded),
    );
  }

  Future<NovelBackgroundRecord> paperTexture({
    required int seed,
    int size = 128,
  }) async {
    final boundedSize = size.clamp(32, 512);
    final id = '${NovelBackgroundIds.paperPrefix}$seed-$boundedSize';
    final directory = await _directory('builtin', create: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}paper-$seed-$boundedSize.png',
    );
    if (await file.exists()) {
      final existing = await _decodeFile(file);
      if (existing != null &&
          existing.width == boundedSize &&
          existing.height == boundedSize) {
        return NovelBackgroundRecord(
          id: id,
          file: file,
          width: boundedSize,
          height: boundedSize,
          averageArgb: _averageArgb(existing),
        );
      }
    }

    final random = Random(seed);
    final image = img.Image(width: boundedSize, height: boundedSize);
    final rowFibers = List<int>.generate(
      boundedSize,
      (_) => random.nextInt(5) - 2,
      growable: false,
    );
    for (var y = 0; y < boundedSize; y++) {
      for (var x = 0; x < boundedSize; x++) {
        final noise = random.nextInt(9) - 4 + rowFibers[y];
        image.setPixelRgba(
          x,
          y,
          (238 + noise).clamp(0, 255),
          (229 + noise).clamp(0, 255),
          (209 + noise).clamp(0, 255),
          255,
        );
      }
    }
    await _writeAtomically(file, img.encodePng(image));
    return NovelBackgroundRecord(
      id: id,
      file: file,
      width: boundedSize,
      height: boundedSize,
      averageArgb: _averageArgb(image),
    );
  }

  Future<NovelBackgroundRecord?> resolve(String id) async {
    if (id.startsWith(NovelBackgroundIds.paperPrefix)) {
      final match = RegExp(r'^builtin:paper-(-?\d+)-(\d+)$').firstMatch(id);
      if (match == null) return null;
      return paperTexture(
        seed: int.parse(match.group(1)!),
        size: int.parse(match.group(2)!),
      );
    }
    final match = RegExp(r'^imported:([a-f0-9]{64})$').firstMatch(id);
    if (match == null) return null;
    final directory = await _directory('imported', create: false);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${match.group(1)}.png',
    );
    final decoded = await _decodeImportedFile(file, match.group(1)!);
    if (decoded == null) return null;
    return NovelBackgroundRecord(
      id: id,
      file: file,
      width: decoded.width,
      height: decoded.height,
      averageArgb: _averageArgb(decoded),
    );
  }

  Future<List<NovelBackgroundRecord>> listImported() async {
    final directory = await _directory('imported', create: false);
    if (!await directory.exists()) return const [];
    final records = <NovelBackgroundRecord>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      final match = RegExp(r'^([a-f0-9]{64})\.png$').firstMatch(name);
      if (match == null) continue;
      final decoded = await _decodeImportedFile(entity, match.group(1)!);
      if (decoded == null) continue;
      records.add(NovelBackgroundRecord(
        id: '${NovelBackgroundIds.importedPrefix}${match.group(1)}',
        file: entity,
        width: decoded.width,
        height: decoded.height,
        averageArgb: _averageArgb(decoded),
      ));
    }
    records.sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(records);
  }

  Future<void> deleteUnreferenced(Set<String> retainedIds) async {
    final directory = await _directory('imported', create: false);
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = RegExp(r'^([a-f0-9]{64})\.png$').firstMatch(
        _basename(entity.path),
      );
      if (match == null) continue;
      final id = '${NovelBackgroundIds.importedPrefix}${match.group(1)}';
      if (!retainedIds.contains(id) && await entity.exists()) {
        await entity.delete();
      }
    }
  }

  Future<Directory> _directory(String name, {required bool create}) async {
    final support = await _applicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}novel_backgrounds'
      '${Platform.pathSeparator}$name',
    );
    if (create) await directory.create(recursive: true);
    return directory;
  }
}

img.Image _decodeValidated(List<int> bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
  } catch (_) {
    decoded = null;
  }
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    throw const NovelBackgroundException(
      NovelBackgroundError.invalidImage,
      'The background file is not a supported image.',
    );
  }
  if (decoded.width > 16384 ||
      decoded.height > 16384 ||
      decoded.width * decoded.height > 100000000) {
    throw const NovelBackgroundException(
      NovelBackgroundError.imageTooLarge,
      'The background image is too large.',
    );
  }
  return decoded;
}

Future<img.Image?> _decodeFile(File file) async {
  try {
    if (!await file.exists()) return null;
    return _decodeValidated(await file.readAsBytes());
  } catch (_) {
    return null;
  }
}

Future<img.Image?> _decodeImportedFile(File file, String digest) async {
  try {
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != digest) return null;
    return _decodeValidated(bytes);
  } catch (_) {
    return null;
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

int _averageArgb(img.Image image) {
  final xStep = max(1, image.width ~/ 64);
  final yStep = max(1, image.height ~/ 64);
  var red = 0;
  var green = 0;
  var blue = 0;
  var count = 0;
  for (var y = 0; y < image.height; y += yStep) {
    for (var x = 0; x < image.width; x += xStep) {
      final pixel = image.getPixel(x, y);
      red += pixel.r.toInt();
      green += pixel.g.toInt();
      blue += pixel.b.toInt();
      count++;
    }
  }
  return 0xff000000 |
      ((red ~/ count) << 16) |
      ((green ~/ count) << 8) |
      (blue ~/ count);
}

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;
