import 'dart:convert';
import 'dart:typed_data';

class PageImageData {
  const PageImageData({
    required this.bytes,
    required this.mediaType,
    required this.extension,
  });

  final Uint8List bytes;
  final String mediaType;
  final String extension;
}

const _supportedMediaTypes = <String>{
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
};

bool isPageImageDataUri(String value) {
  final commaIndex = value.indexOf(',');
  if (commaIndex < 0) return false;

  final metadata = value.substring(0, commaIndex).toLowerCase();
  if (!metadata.startsWith('data:') || !metadata.endsWith(';base64')) {
    return false;
  }

  final mediaType = metadata.substring(5, metadata.length - 7);
  return mediaType.isEmpty || _supportedMediaTypes.contains(mediaType);
}

String detectPageImageMediaType(Uint8List bytes) {
  if (_startsWith(bytes, const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ])) {
    return 'image/png';
  }
  if (_startsWith(bytes, const [0xff, 0xd8, 0xff])) {
    return 'image/jpeg';
  }
  if (_startsWith(bytes, ascii.encode('GIF87a')) ||
      _startsWith(bytes, ascii.encode('GIF89a'))) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      _matchesAt(bytes, 0, const [0x52, 0x49, 0x46, 0x46]) &&
      _matchesAt(bytes, 8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }

  throw const FormatException('不支持的图片数据格式');
}

PageImageData decodePageImageDataUri(String value) {
  if (!isPageImageDataUri(value)) {
    throw const FormatException('不支持的图片数据格式');
  }

  final commaIndex = value.indexOf(',');
  final metadata = value.substring(5, commaIndex).toLowerCase();
  final declaredMediaType = metadata.substring(0, metadata.length - 7);

  late final Uint8List bytes;
  try {
    bytes = base64Decode(value.substring(commaIndex + 1));
  } on FormatException {
    throw const FormatException('无效的 Base64 图片数据');
  }

  final detectedMediaType = detectPageImageMediaType(bytes);
  if (declaredMediaType.isNotEmpty && declaredMediaType != detectedMediaType) {
    throw const FormatException('不支持的图片数据格式');
  }

  return PageImageData(
    bytes: bytes,
    mediaType: detectedMediaType,
    extension: switch (detectedMediaType) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => throw const FormatException('不支持的图片数据格式'),
    },
  );
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  return _matchesAt(bytes, 0, signature);
}

bool _matchesAt(Uint8List bytes, int offset, List<int> signature) {
  if (bytes.length < offset + signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}
