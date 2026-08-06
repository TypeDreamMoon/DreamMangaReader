import 'package:dream_manga_reader/app/download_store.dart';
import 'package:dream_manga_reader/app/legacy_download_migrator.dart';
import 'package:dream_manga_reader/app/novel_download_store.dart';
import 'package:dream_manga_reader/core/downloads/download_task.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps completed manga and novel records without transport data', () {
    const source = SourceMeta(
      id: 'source:with:punctuation',
      name: '测试源',
      script: 'https://private.example/source.js',
      kind: 'novel',
    );
    final manga = DownloadedChapter(
      sourceId: source.id,
      mangaId: 'manga/1',
      mangaTitle: '漫画',
      mangaCover: 'https://private.example/cover.jpg',
      chapterId: 'chapter:1',
      chapterName: '第一话',
      dir: r'D:\offline\manga\chapter-1',
      pageCount: 12,
      doneAt: 1000,
    );
    const novel = DownloadedNovelChapter(
      source: source,
      novel: Novel(
        id: 'novel/1',
        title: '小说',
        url: 'https://private.example/novel',
      ),
      chapter: NovelChapter(id: 'chapter:1', title: '第一章'),
      directory: r'D:\offline\novel\chapter-1',
      resourceCount: 3,
      byteCount: 4096,
      completedAt: 2000,
    );

    final tasks = LegacyDownloadMigrator.buildTasks(
      manga: [manga],
      novels: [novel],
    );

    expect(tasks, hasLength(2));
    expect(tasks.every((task) => task.state == DownloadTaskState.completed),
        isTrue);
    expect(tasks.map((task) => task.kind), {
      DownloadContentKind.manga,
      DownloadContentKind.novel,
    });
    expect(tasks[0].payload['localDirectory'], manga.dir);
    expect(tasks[1].payload['localDirectory'], novel.directory);
    final stored = tasks.map((task) => task.toJson().toString()).join();
    expect(stored, isNot(contains('private.example')));
    expect(stored, isNot(contains('source.js')));
  });

  test('legacy identities are stable and collision resistant', () {
    final left = DownloadedChapter(
      sourceId: 'a:b',
      mangaId: 'c',
      mangaTitle: '左',
      chapterId: 'd',
      chapterName: '章节',
      dir: 'left',
      pageCount: 1,
      doneAt: 1,
    );
    final right = DownloadedChapter(
      sourceId: 'a',
      mangaId: 'b:c',
      mangaTitle: '右',
      chapterId: 'd',
      chapterName: '章节',
      dir: 'right',
      pageCount: 1,
      doneAt: 1,
    );

    final first = LegacyDownloadMigrator.buildTasks(manga: [left]);
    final repeated = LegacyDownloadMigrator.buildTasks(manga: [left]);
    final other = LegacyDownloadMigrator.buildTasks(manga: [right]);

    expect(first.single.id, repeated.single.id);
    expect(first.single.id, isNot(other.single.id));
  });
}
