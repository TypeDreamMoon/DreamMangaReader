import 'package:dream_manga_reader/core/novel/novel_document_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('private novel data images', () {
    test('keeps only supported raster Base64 image sources', () {
      const png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
      const jpeg = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2Q==';
      const gif = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';
      const webp = 'data:image/webp;base64,UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEAAUAmJaQAA3AA/v89WAAAAA==';

      final sanitized = NovelDocumentSanitizer.sanitize(
        '<img src="$png"><img src="$jpeg">'
        '<img src="$gif"><img src="$webp">',
      );

      expect(sanitized, contains(png));
      expect(sanitized, contains(jpeg));
      expect(sanitized, contains(gif));
      expect(sanitized, contains(webp));
    });

    test('drops active SVG and malformed data URLs', () {
      final sanitized = NovelDocumentSanitizer.sanitize(
        '<img src="data:text/html;base64,PHNjcmlwdD4=">'
        '<img src="data:image/svg+xml;base64,PHN2Zz4=">'
        '<img src="data:image/png;base64,not valid!">',
      );

      expect(sanitized, isNot(contains('data:text/html')));
      expect(sanitized, isNot(contains('image/svg+xml')));
      expect(sanitized, isNot(contains('not valid!')));
    });
  });
}
