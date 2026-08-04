import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dream_manga_reader/core/source/page_image_data.dart';
import 'package:dream_manga_reader/core/source/models.dart';
import 'package:dream_manga_reader/features/reader/reader_page.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const onePixelPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  group('isPageImageDataUri', () {
    test('recognizes image and omitted media type data URIs', () {
      expect(
        isPageImageDataUri('data:image/webp;base64,UklGRjAwMDBXRUJQ'),
        isTrue,
      );
      expect(
        isPageImageDataUri('data:;base64,UklGRjAwMDBXRUJQ'),
        isTrue,
      );
    });

    test('rejects network URLs and non-image data URIs', () {
      expect(isPageImageDataUri('https://example.com/page.webp'), isFalse);
      expect(
        isPageImageDataUri('data:text/html;base64,PGh0bWw+'),
        isFalse,
      );
    });
  });

  group('decodePageImageDataUri', () {
    test('decodes a declared WebP image', () {
      final image = decodePageImageDataUri(
        'data:image/webp;base64,UklGRjAwMDBXRUJQ',
      );

      expect(image.mediaType, 'image/webp');
      expect(image.extension, 'webp');
      expect(image.bytes.sublist(0, 4), ascii.encode('RIFF'));
    });

    test('sniffs WebP when the media type is omitted', () {
      final image = decodePageImageDataUri(
        'data:;base64,UklGRjAwMDBXRUJQ',
      );

      expect(image.mediaType, 'image/webp');
      expect(image.extension, 'webp');
    });

    test('accepts supported image signatures', () {
      final fixtures = <(
        String mediaType,
        String extension,
        List<int> bytes,
      )>[
        ('image/png', 'png', [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        ('image/jpeg', 'jpg', [0xff, 0xd8, 0xff, 0xe0]),
        ('image/gif', 'gif', ascii.encode('GIF89a')),
      ];

      for (final fixture in fixtures) {
        final uri = 'data:${fixture.$1};base64,'
            '${base64Encode(fixture.$3)}';
        final image = decodePageImageDataUri(uri);

        expect(image.mediaType, fixture.$1);
        expect(image.extension, fixture.$2);
        expect(image.bytes, Uint8List.fromList(fixture.$3));
      }
    });

    test('rejects a network URL', () {
      expect(
        () => decodePageImageDataUri('https://example.com/page.webp'),
        throwsFormatException,
      );
    });

    test('rejects a non-image data URI', () {
      expect(
        () => decodePageImageDataUri('data:text/html;base64,PGh0bWw+'),
        throwsFormatException,
      );
    });

    test('reports invalid Base64 image data', () {
      expect(
        () => decodePageImageDataUri('data:image/png;base64,%%%'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '无效的 Base64 图片数据',
          ),
        ),
      );
    });

    test('rejects a declared media type that mismatches the signature', () {
      expect(
        () => decodePageImageDataUri(
          'data:image/png;base64,UklGRjAwMDBXRUJQ',
        ),
        throwsFormatException,
      );
    });

    test('reports an unknown image signature', () {
      expect(
        () => decodePageImageDataUri('data:;base64,AAECAw=='),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '不支持的图片数据格式',
          ),
        ),
      );
    });
  });

  group('page image integration helpers', () {
    test('writes a data image to a materialized file', () async {
      final temp = await Directory.systemTemp.createTemp('page-image-data-');
      addTearDown(() => temp.delete(recursive: true));
      final output = File('${temp.path}/page.png');

      await writePageImageDataUri(onePixelPng, output);

      expect(await output.readAsBytes(),
          decodePageImageDataUri(onePixelPng).bytes);
    });

    test('chooses file extensions for data, network, and local pages', () {
      expect(pageImageExtension(onePixelPng), 'png');
      expect(pageImageExtension('https://img.test/page.webp?token=1'), 'webp');
      expect(pageImageExtension(r'C:\pages\0.img'), 'jpg');
    });

    test('reader creates a MemoryImage for data pages', () {
      final provider = readerPageImageProvider(
        const PageImage(index: 0, url: onePixelPng),
        const {},
      );

      expect(provider, isA<MemoryImage>());
    });
  });
}
