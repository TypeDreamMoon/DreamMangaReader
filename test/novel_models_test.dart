import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote and local novel keys never collide', () {
    expect(NovelIdentity.remote('s', 'n').key, 'remote:s:n');
    expect(NovelIdentity.local('abc').key, 'local:abc');
  });

  test('document rejects unsupported format and unsafe empty identity', () {
    expect(
      () => NovelDocument(format: NovelDocumentFormat.html, content: ''),
      throwsArgumentError,
    );
    expect(
      NovelLocator(chapterId: 'c1', blockId: 'p12', fraction: 1.7).fraction,
      1.0,
    );
  });

  test('models preserve volume and chapter navigation metadata', () {
    const chapter = NovelChapter(
      id: 'c1',
      title: '第一章',
      number: 1,
      volumeId: 'v1',
      volumeTitle: '第一卷',
    );
    expect(chapter.volumeTitle, '第一卷');
  });

  test('identity rejects blank components and locator clamps lower bound', () {
    expect(() => NovelIdentity.remote('', 'n'), throwsArgumentError);
    expect(() => NovelIdentity.remote('s', '  '), throwsArgumentError);
    expect(() => NovelIdentity.local(''), throwsArgumentError);
    expect(
      NovelLocator(chapterId: 'c1', fraction: -0.2).fraction,
      0.0,
    );
  });

  test('source metadata distinguishes manga, anime, and novel kinds', () {
    const manga = SourceMeta(id: 'm', name: 'm', script: '');
    const anime = SourceMeta(id: 'a', name: 'a', script: '', kind: 'anime');
    const novel = SourceMeta(id: 'n', name: 'n', script: '', kind: 'novel');

    expect(manga.isManga, isTrue);
    expect(manga.isNovel, isFalse);
    expect(anime.isAnime, isTrue);
    expect(novel.isNovel, isTrue);
    expect(novel.isManga, isFalse);
  });
}
