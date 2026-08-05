import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

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

/// 最近解码过的 Base64 页(URI → 字节)。
///
/// **必须缓存**:[MemoryImage] 的相等性按 `bytes` 的**实例**比,每次 build 重新
/// 解码都会得到新的 Uint8List → Flutter 的 ImageCache 永远命不中,每帧把整张图
/// 重解一遍。缓存后同一页拿到的是同一个实例,provider 才等价、缓存才生效。
///
/// 只留最近 [_decodedCacheLimit] 张:阅读器同时用到的就是当前页 + 预加载窗口,
/// 再多就是白占内存(一张页的字节可能有几 MB)。
const int _decodedCacheLimit = 12;
final Map<String, PageImageData> _decodedCache = <String, PageImageData>{};

PageImageData decodePageImageDataUri(String value) {
  // Dart 的 Map 保插入序 → remove + 重插 = 把命中项挪到队尾,队首即最久未用。
  final cached = _decodedCache.remove(value);
  if (cached != null) {
    _decodedCache[value] = cached;
    return cached;
  }
  final decoded = _decodePageImageDataUri(value);
  _decodedCache[value] = decoded;
  if (_decodedCache.length > _decodedCacheLimit) {
    _decodedCache.remove(_decodedCache.keys.first);
  }
  return decoded;
}

PageImageData _decodePageImageDataUri(String value) {
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

String pageImageExtension(String value) {
  if (isPageImageDataUri(value)) {
    return decodePageImageDataUri(value).extension;
  }
  final withoutQuery = value.split(RegExp(r'[?#]')).first;
  final match = RegExp(r'\.([A-Za-z0-9]{1,4})$').firstMatch(withoutQuery);
  final extension = match?.group(1)?.toLowerCase();
  if (const {'jpg', 'jpeg', 'png', 'gif', 'webp'}.contains(extension)) {
    return extension == 'jpeg' ? 'jpg' : extension!;
  }
  return 'jpg';
}

/// 把 Base64 页落到磁盘,**按内容寻址**(文件名 = 字节的 sha1)。
///
/// 保存/分享要一个真实文件路径。用 URI 的 `String.hashCode` 当文件名是不行的:
/// 32 位、非密码学散列,一话几百页时撞名的后果是**存出去的是别的页**。
Future<File> materializePageImageDataUri(String value, Directory root) async {
  final image = decodePageImageDataUri(value);
  final digest = sha1.convert(image.bytes).toString();
  final output = File('${root.path}/page-images/$digest.${image.extension}');
  if (await output.exists()) return output; // 同内容不重写
  await output.parent.create(recursive: true);
  await output.writeAsBytes(image.bytes, flush: true);
  return output;
}

Future<File> writePageImageDataUri(String value, File output) async {
  final image = decodePageImageDataUri(value);
  await output.parent.create(recursive: true);
  await output.writeAsBytes(image.bytes, flush: true);
  return output;
}

typedef PageImageNetworkFetcher = Future<File> Function(
  String url,
  Map<String, String> headers,
);

Future<File> writePageImage({
  required PageImage image,
  required File output,
  required Map<String, String> headers,
  required PageImageNetworkFetcher fetchNetwork,
}) async {
  await output.parent.create(recursive: true);
  if (isPageImageDataUri(image.url)) {
    return writePageImageDataUri(image.url, output);
  }
  if (image.url.startsWith('http')) {
    final cached = await fetchNetwork(image.url, headers);
    return cached.copy(output.path);
  }
  return File(image.url).copy(output.path);
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
