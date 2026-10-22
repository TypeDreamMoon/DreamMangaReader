// 「哪几条属于同一部剧、这份库该叫什么」的纯函数测试。
//
// 这块是「一部剧加两集变成两张卡」的正面解法,规则一旦松掉,用户就会看到
// 要么满屏单集卡、要么两部剧被塞进同一张卡,所以这里把每种形态都钉住。
import 'package:dream_manga_reader/core/local/local_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  LocalMediaItem item({
    required String title,
    required String location,
    int? season,
    int? episode,
  }) =>
      LocalMediaItem(
        id: '',
        libraryId: '',
        title: title,
        location: location,
        season: season,
        episode: episode,
      );

  group('localSeriesKey', () {
    test('大小写与常见分隔符都不参与比较', () {
      final key = localSeriesKey('Loki');
      expect(localSeriesKey('LOKI'), key);
      expect(localSeriesKey('  loki  '), key);
      expect(localSeriesKey('Loki.'), key);
      expect(localSeriesKey('Loki-'), key);
      expect(localSeriesKey('《Loki》'), key);
      // 括号里的年份由文件名解析器先清掉(见 local_episode_parser_test),不归这里管。
      expect(localSeriesKey('Loki 第二季'), isNot(key));
    });

    test('不同剧的键不同;中文标题照常', () {
      expect(localSeriesKey('Loki'), isNot(localSeriesKey('The Boys')));
      expect(localSeriesKey('我的英雄学院'), '我的英雄学院');
      expect(localSeriesKey('我的英雄学院'), isNot(localSeriesKey('我的英雄学院 第二季')));
    });
  });

  group('groupLocalItemsForLibraries', () {
    test('同一部剧的散集归成一组,名字用剧名', () {
      final groups = groupLocalItemsForLibraries([
        item(
          title: 'Loki',
          location: r'C:\Media\Loki.S02E05.2160p.mov',
          season: 2,
          episode: 5,
        ),
        item(
          title: 'Loki',
          location: r'C:\Media\Loki.S02E06.2160p.mov',
          season: 2,
          episode: 6,
        ),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.key, 'series:loki');
      expect(groups.single.name, 'Loki');
      expect(groups.single.items, hasLength(2));
    });

    test('标题写法不同但归一化后同剧,仍然归一组', () {
      final groups = groupLocalItemsForLibraries([
        item(
          title: 'Loki',
          location: r'C:\a\Loki.S01E01.mkv',
          season: 1,
          episode: 1,
        ),
        item(
          title: 'LOKI.',
          location: r'C:\b\loki.s01e02.mkv',
          season: 1,
          episode: 2,
        ),
      ]);

      expect(groups, hasLength(1));
      // 组名取出现次数最多的那个写法(并列时取先出现的)。
      expect(groups.single.name, 'Loki');
    });

    test('一次挑两部剧就分成两组', () {
      final groups = groupLocalItemsForLibraries([
        item(
          title: 'Loki',
          location: r'C:\Media\Loki.S02E06.mov',
          season: 2,
          episode: 6,
        ),
        item(
          title: 'The Boys',
          location: r'C:\Media\The.Boys.S01E01.mkv',
          season: 1,
          episode: 1,
        ),
      ]);

      expect(groups.map((g) => g.name), ['Loki', 'The Boys']);
      expect(groups.map((g) => g.items.length), [1, 1]);
    });

    test('没有季集号的按目录归堆,名字用目录名', () {
      final groups = groupLocalItemsForLibraries([
        item(title: 'Inception', location: r'C:\Media\Movies\Inception.mkv'),
        item(title: 'Interstellar', location: r'C:\Media\Movies\Interstellar.mkv'),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.key, r'dir:C:/Media/Movies');
      expect(groups.single.name, 'Movies');
    });

    test('散装文件按目录分开;只有带季集号的才按剧名走', () {
      final groups = groupLocalItemsForLibraries([
        item(title: 'Inception', location: r'C:\A\Inception.mkv'),
        item(title: 'Interstellar', location: r'C:\B\Interstellar.mkv'),
        item(
          title: 'Loki',
          location: r'C:\C\Loki.S01E01.mkv',
          episode: 1,
        ),
      ]);

      expect(groups, hasLength(3));
      expect(groups.map((g) => g.name), ['A', 'B', 'Loki']);
      expect(groups.map((g) => g.items.length), [1, 1, 1]);
    });

    test('SAF 上的散装文件按「解码后的目录」归堆,不是全挤在一个 document 下', () {
      const folderA = 'content://com.android.externalstorage.documents/document/'
          'primary%3AMovies%2F';
      const folderB = 'content://com.android.externalstorage.documents/document/'
          'primary%3ADownload%2F';
      final groups = groupLocalItemsForLibraries([
        item(title: 'Inception', location: '${folderA}Inception.mkv'),
        item(title: 'Interstellar', location: '${folderA}Interstellar.mkv'),
        item(title: 'Arrival', location: '${folderB}Arrival.mkv'),
      ]);

      expect(groups, hasLength(2));
      expect(groups.map((g) => g.name), ['Movies', 'Download']);
      expect(groups.map((g) => g.items.length), [2, 1]);
      expect(groups.first.key, 'dir:primary:Movies');
    });

    test('顺序按每组第一条出现的先后,结果稳定', () {
      final groups = groupLocalItemsForLibraries([
        item(title: 'The Boys', location: r'C:\a\The.Boys.S01E01.mkv', episode: 1),
        item(title: 'Loki', location: r'C:\a\Loki.S02E06.mov', episode: 6),
        item(title: 'The Boys', location: r'C:\a\The.Boys.S01E02.mkv', episode: 2),
      ]);

      expect(groups.map((g) => g.name), ['The Boys', 'Loki']);
      expect(groups.first.items, hasLength(2));
    });

    test('空输入给空结果', () {
      expect(groupLocalItemsForLibraries(const []), isEmpty);
    });
  });

  group('localParentKey / localParentDisplayName', () {
    test('Windows 路径取父目录与最后一段目录名', () {
      expect(localParentKey(r'C:\Media\Movies\Inception.mkv'), 'C:/Media/Movies');
      expect(
        localParentDisplayName(r'C:\Media\Movies\Inception.mkv'),
        'Movies',
      );
    });

    test('SAF document uri:解码 docId 再取目录,别把 /document 当目录', () {
      const fileUri = 'content://com.android.externalstorage.documents/document/'
          'primary%3AMovies%2FLoki.S02E06.mov';
      expect(localParentKey(fileUri), 'primary:Movies');
      expect(localParentDisplayName(fileUri), 'Movies');

      const nested = 'content://com.android.externalstorage.documents/document/'
          'primary%3AMedia%2FMovies%2FInception.mkv';
      expect(localParentKey(nested), 'primary:Media/Movies');
      expect(localParentDisplayName(nested), 'Movies');
    });

    test('SAF tree uri(指向目录本身)也取得到目录名', () {
      const tree = 'content://com.android.externalstorage.documents/tree/'
          'primary%3AMovies';
      expect(localParentKey(tree), 'primary:Movies');
      expect(localParentDisplayName(tree), 'Movies');
    });

    test('同一个 SAF 目录下的两个文件给同一个键', () {
      const a = 'content://com.android.externalstorage.documents/document/'
          'primary%3AMovies%2FInception.mkv';
      const b = 'content://com.android.externalstorage.documents/document/'
          'primary%3AMovies%2FArrival.mkv';
      expect(localParentKey(a), localParentKey(b));
    });

    test('拿不到目录名时返回空串', () {
      expect(localParentDisplayName('Inception.mkv'), '');
      expect(localParentDisplayName(''), '');
    });
  });
}
