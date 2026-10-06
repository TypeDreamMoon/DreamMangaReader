import 'package:dream_manga_reader/core/local/local_episode_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用「文件名 → 解析结果」的比较器，模拟列表排序的真实用法。
int _compareByName(String a, String b) => compareEpisodes(
      a: parseMediaFileName(a),
      nameA: a,
      b: parseMediaFileName(b),
      nameB: b,
    );

void main() {
  group('季集识别：SxxExx 形态', () {
    test('S01E02 带噪声后缀', () {
      final parsed = parseMediaFileName('Show.S01E02.1080p.mkv');
      expect(parsed.title, 'Show');
      expect(parsed.season, 1);
      expect(parsed.episode, 2);
    });

    test('小写 s1e2 与不补零', () {
      final parsed = parseMediaFileName('show.s1e2.mkv');
      expect(parsed.title, 'show');
      expect(parsed.season, 1);
      expect(parsed.episode, 2);
    });

    test('点分隔 S01.E02 与 EP 写法 S01_EP2', () {
      expect(parseMediaFileName('Show.S01.E02.mkv').episode, 2);
      expect(parseMediaFileName('Show.S01_EP2.mkv').season, 1);
      expect(parseMediaFileName('Show.S01_EP2.mkv').episode, 2);
    });

    test('季集号从标题里被抠掉', () {
      expect(parseMediaFileName('Show.S01E02.mkv').title, 'Show');
      // 集号后面还有年份时，年份留在标题里（它不是噪声词，是作品名的一部分）。
      expect(parseMediaFileName('Show.2019.S01E02.mkv').title, 'Show 2019');
    });

    test('三位数集号 S01E100', () {
      final parsed = parseMediaFileName('Show.S01E100.mkv');
      expect(parsed.season, 1);
      expect(parsed.episode, 100);
    });
  });

  group('季集识别：其它形态', () {
    test('1x02', () {
      final parsed = parseMediaFileName('Show.1x02.mkv');
      expect(parsed.season, 1);
      expect(parsed.episode, 2);
      expect(parsed.title, 'Show');
    });

    test('1920x1080 不会被当成年份季集', () {
      final parsed = parseMediaFileName('Show.1920x1080.mkv');
      expect(parsed.season, isNull);
      expect(parsed.episode, isNull);
      expect(parsed.title, 'Show');
    });

    test('第 12 话 / 第12集 / 第3期 / 第2部 都算集号', () {
      expect(parseMediaFileName('影片名 第 12 话.mkv').episode, 12);
      expect(parseMediaFileName('影片名 第12集.mkv').episode, 12);
      expect(parseMediaFileName('综艺 第3期.mkv').episode, 3);
      expect(parseMediaFileName('作品 第2部.mkv').episode, 2);
      expect(parseMediaFileName('影片名 第 12 话.mkv').title, '影片名');
    });

    test('第2季 是季号而不是集号', () {
      final parsed = parseMediaFileName('Show.第2季.mkv');
      expect(parsed.season, 2);
      expect(parsed.episode, isNull);
      expect(parsed.title, 'Show');
    });

    test('Season 2 是季号', () {
      final parsed = parseMediaFileName('Show Season 2.mkv');
      expect(parsed.season, 2);
      expect(parsed.title, 'Show');
    });

    test('裸的 S02 是季号', () {
      final parsed = parseMediaFileName('Show.S02.1080p.WEB-DL.mkv');
      expect(parsed.season, 2);
      expect(parsed.episode, isNull);
      expect(parsed.title, 'Show');
    });

    test('单词里的 S1 / E 不会被误判（S1mpsons）', () {
      final parsed = parseMediaFileName('The.S1mpsons.mkv');
      expect(parsed.season, isNull);
      expect(parsed.episode, isNull);
      expect(parsed.title, 'The S1mpsons');
    });

    test('EP12 / E12 是集号', () {
      expect(parseMediaFileName('Show EP12.mkv').episode, 12);
      expect(parseMediaFileName('Show E12.mkv').episode, 12);
      expect(parseMediaFileName('Show.E12.mkv').episode, 12);
      // 「Episode」这个词本身不带数字，不该造出集号；带数字时走尾部规则。
      expect(parseMediaFileName('Show Episode.mkv').episode, isNull);
      expect(parseMediaFileName('Show Episode 12.mkv').episode, 12);
    });

    test('方括号里的纯数字 [12]', () {
      final parsed = parseMediaFileName('Show [12].mkv');
      expect(parsed.episode, 12);
      expect(parsed.title, 'Show');
    });

    test('方括号里的 4 位数不当集号', () {
      expect(parseMediaFileName('Show [1080].mkv').episode, isNull);
    });

    test('尾部 - 12', () {
      final parsed = parseMediaFileName('Show - 12.mkv');
      expect(parsed.episode, 12);
      expect(parsed.title, 'Show');
    });

    test('尾部集号后面还挂着噪声方括号', () {
      final parsed = parseMediaFileName('Show 12 [1080p].mkv');
      expect(parsed.episode, 12);
      expect(parsed.title, 'Show');
    });

    test('文件名本身就是数字', () {
      final parsed = parseMediaFileName('12.mkv');
      expect(parsed.episode, 12);
      expect(parsed.season, isNull);
    });

    test('尾部 4 位数是年份不是集号', () {
      final dotted = parseMediaFileName('Movie.2020.mkv');
      expect(dotted.episode, isNull);
      expect(dotted.title, 'Movie 2020');

      final spaced = parseMediaFileName('Movie 2020.mkv');
      expect(spaced.episode, isNull);
      expect(spaced.title, 'Movie 2020');
    });

    test('点号尾随的数字仍算集号（不被当扩展名吃掉）', () {
      final parsed = parseMediaFileName('Naruto.12.mkv');
      expect(parsed.episode, 12);
      expect(parsed.title, 'Naruto');
    });

    test('全角数字与全角字母也能识别', () {
      final parsed = parseMediaFileName('ＳＨＯＷ　第０１話.mkv');
      expect(parsed.episode, 1);
      expect(parsed.title, 'SHOW');
    });
  });

  group('噪声清理', () {
    test('字幕组 + 分辨率 + 编码 + 音轨一次清干净', () {
      final parsed =
          parseMediaFileName('[字幕组] 影片名 - 12 [1080p][x264][AAC].mkv');
      expect(parsed.title, '影片名');
      expect(parsed.episode, 12);
      expect(parsed.season, isNull);
    });

    test('开头的无空格方括号按字幕组名处理', () {
      final parsed = parseMediaFileName('[FLsnow] Show - 01 [1080p].mkv');
      expect(parsed.title, 'Show');
      expect(parsed.episode, 1);
    });

    test('CRC32 括号被清掉', () {
      final parsed = parseMediaFileName('Show.S01E02.1080p.[ABCD1234].mkv');
      expect(parsed.title, 'Show');
      expect(parsed.episode, 2);
    });

    test('来源与位深噪声被清掉', () {
      final parsed = parseMediaFileName(
        'Movie.2019.1080p.BluRay.x265.HEVC.10bit.AAC.BDRip.mkv',
      );
      expect(parsed.title, 'Movie 2019');
      expect(parsed.episode, isNull);
    });

    test('括号里的年份被清掉', () {
      expect(parseMediaFileName('Movie (2019).mkv').title, 'Movie');
      expect(parseMediaFileName('Movie {2019}.mkv').title, 'Movie');
    });

    test('分隔符归一到单个空格且不留首尾空格', () {
      final parsed = parseMediaFileName('My__Movie...2019  1080p.mkv');
      expect(parsed.title, 'My Movie 2019');
      expect(parsed.title.contains('  '), isFalse);
      expect(parsed.title.trim(), parsed.title);
    });

    test('中文标签不作为标题的一部分', () {
      expect(parseMediaFileName('影片名.简体.第01话.mkv').title, '影片名');
    });

    test('整体被括号包裹的标题会拆掉括号', () {
      expect(parseMediaFileName('[银魂] 第001话.mkv').title, '银魂');
    });

    test('带空格的方括号保留（那通常是标题）', () {
      expect(parseMediaFileName('[Movie Title] 第01话.mkv').title, 'Movie Title');
    });
  });

  group('compareNatural', () {
    test('数字段按数值比较', () {
      expect(compareNatural('Episode 9', 'Episode 10'), lessThan(0));
      expect(compareNatural('a10', 'a9'), greaterThan(0));
      expect(compareNatural('1', '02'), lessThan(0));
    });

    test('大小写不敏感', () {
      expect(compareNatural('ABC', 'abc'), 0);
      expect(compareNatural('apple', 'Banana'), lessThan(0));
    });

    test('数字段排在非数字段前面', () {
      expect(compareNatural('2', 'apple'), lessThan(0));
    });

    test('前缀短的排前面', () {
      expect(compareNatural('a', 'a1'), lessThan(0));
    });

    test('超长数字段不崩也不溢出', () {
      final short = 'v1${'0' * 30}';
      final long = 'v1${'0' * 29}1';
      expect(compareNatural(short, long), lessThan(0));
      expect(compareNatural(long, short), greaterThan(0));
    });
  });

  group('compareEpisodes 排序', () {
    test('S1E10 排在 S1E9 之后', () {
      final names = <String>[
        'Show.S01E10.mkv',
        'Show.S01E09.mkv',
        'Show.S01E02.mkv',
      ]..sort(_compareByName);
      expect(names, <String>[
        'Show.S01E02.mkv',
        'Show.S01E09.mkv',
        'Show.S01E10.mkv',
      ]);
    });

    test('季号优先于集号', () {
      final names = <String>[
        'Show.S02E01.mkv',
        'Show.S01E10.mkv',
      ]..sort(_compareByName);
      expect(names.first, 'Show.S01E10.mkv');
    });

    test('无集号的条目排在最后', () {
      // 规范 §5.3 的排序键是 `(season ?? 0, episode ?? 大数)`：只有两边都无季号时，
      // 「无集号排最后」才成立，所以这里的样本用不带季号的 E01/E03。
      final names = <String>[
        'Show.SP01.mkv',
        'Show.E03.mkv',
        'Show.E01.mkv',
      ]..sort(_compareByName);
      expect(names, <String>[
        'Show.E01.mkv',
        'Show.E03.mkv',
        'Show.SP01.mkv',
      ]);
    });

    test('带季号的集子按规范排在无季号条目之后（季号缺省视为 0）', () {
      final names = <String>[
        'Show.S01E01.mkv',
        'Show.SP01.mkv',
      ]..sort(_compareByName);
      expect(names.first, 'Show.SP01.mkv');
    });

    test('同季同集时按标题自然序，再按原始文件名', () {
      final names = <String>[
        'Show.S01E01.b.mkv',
        'Show.S01E01.a.mkv',
      ]..sort(_compareByName);
      expect(names.first, 'Show.S01E01.a.mkv');
    });

    test('无季号的按第 0 季处理（排在第一季之前）', () {
      final names = <String>[
        'Show.S01E01.mkv',
        'Show.E01.mkv',
      ]..sort(_compareByName);
      expect(names.first, 'Show.E01.mkv');
    });
  });

  group('扩展名白名单', () {
    test('视频扩展名大小写不敏感', () {
      expect(isVideoFileName('a.mkv'), isTrue);
      expect(isVideoFileName('a.MKV'), isTrue);
      expect(isVideoFileName('a.Mp4'), isTrue);
      expect(isVideoFileName('a.m2ts'), isTrue);
      for (final extension in <String>[
        'mp4',
        'mkv',
        'webm',
        'avi',
        'mov',
        'm4v',
        'ts',
        'm2ts',
        'flv',
        'wmv',
        'mpg',
        'mpeg',
        'ogv',
      ]) {
        expect(isVideoFileName('file.$extension'), isTrue, reason: extension);
      }
    });

    test('非白名单与无扩展名都不是视频', () {
      expect(isVideoFileName('a.txt'), isFalse);
      expect(isVideoFileName('a.part'), isFalse);
      expect(isVideoFileName('a'), isFalse);
      expect(isVideoFileName(''), isFalse);
      expect(isVideoFileName('.mkv'), isFalse);
      expect(isVideoFileName('a.1080p'), isFalse);
    });

    test('音频与字幕扩展名', () {
      for (final extension in <String>[
        'mp3',
        'flac',
        'aac',
        'm4a',
        'ogg',
        'opus',
        'wav',
      ]) {
        expect(isAudioFileName('file.$extension'), isTrue, reason: extension);
      }
      expect(isAudioFileName('file.FLAC'), isTrue);
      expect(isAudioFileName('file.mkv'), isFalse);

      for (final extension in <String>['srt', 'ass', 'ssa', 'vtt', 'sub']) {
        expect(isSubtitleFileName('file.$extension'), isTrue, reason: extension);
      }
      expect(isSubtitleFileName('file.ASS'), isTrue);
      expect(isSubtitleFileName('file.mp4'), isFalse);
      expect(isSubtitleFileName('file'), isFalse);
    });
  });

  group('字幕语言推断', () {
    test('简中标签', () {
      expect(subtitleLanguageFor('movie.zh.ass'), 'zh');
      expect(subtitleLanguageFor('movie.chs.srt'), 'zh');
      expect(subtitleLanguageFor('movie.zh-cn.srt'), 'zh');
      expect(subtitleLanguageFor('movie.zh-hans.srt'), 'zh');
      expect(subtitleLanguageFor('movie.CHS.srt'), 'zh');
    });

    test('繁中标签', () {
      expect(subtitleLanguageFor('movie.cht.ass'), 'zh-Hant');
      expect(subtitleLanguageFor('movie.zh-hant.ass'), 'zh-Hant');
      expect(subtitleLanguageFor('movie.zh-tw.srt'), 'zh-Hant');
      expect(subtitleLanguageFor('movie.big5.srt'), 'zh-Hant');
    });

    test('日文与英文标签', () {
      expect(subtitleLanguageFor('movie.jp.srt'), 'ja');
      expect(subtitleLanguageFor('movie.ja.ass'), 'ja');
      expect(subtitleLanguageFor('movie.jpn.ass'), 'ja');
      expect(subtitleLanguageFor('movie.en.srt'), 'en');
      expect(subtitleLanguageFor('movie.eng.srt'), 'en');
    });

    test('文件名里的中文词', () {
      expect(subtitleLanguageFor('影片名.简体.ass'), 'zh');
      expect(subtitleLanguageFor('影片名.繁体.ass'), 'zh-Hant');
      expect(subtitleLanguageFor('影片名.中文.srt'), 'zh');
      expect(subtitleLanguageFor('影片名.双语.简体.srt'), 'zh');
    });

    test('日文/英文的中文词', () {
      expect(subtitleLanguageFor('影片名.日文.srt'), 'ja');
      expect(subtitleLanguageFor('影片名.英文.srt'), 'en');
    });

    test('推断不到返回 null', () {
      expect(subtitleLanguageFor('movie.srt'), isNull);
      expect(subtitleLanguageFor('movie.unknown.srt'), isNull);
      expect(subtitleLanguageFor(''), isNull);
    });
  });

  group('字幕显示标签', () {
    test('推断到时给中文标签', () {
      expect(subtitleLabelFor('影片名.zh.ass'), '简体');
      expect(subtitleLabelFor('影片名.cht.ass'), '繁体');
      expect(subtitleLabelFor('影片名.jp.srt'), '日文');
      expect(subtitleLabelFor('影片名.en.srt'), '英文');
    });

    test('推断不到时退回去掉扩展名的文件名', () {
      expect(subtitleLabelFor('movie.srt'), 'movie');
      expect(subtitleLabelFor('movie.unknown.srt'), 'movie.unknown');
      expect(subtitleLabelFor(''), '');
    });
  });

  group('字幕配对', () {
    test('同 basename 与语言后缀后缀都配上，movie2.srt 不配', () {
      final matched = subtitlesForVideo(
        videoFileName: 'movie.mkv',
        directoryFileNames: <String>[
          'movie.srt',
          'movie.zh.ass',
          'movie.chs.srt',
          'movie.简体.ass',
          'movie2.srt',
          'other.mkv',
          'movie.txt',
          'movie',
        ],
      );
      expect(matched, <String>[
        'movie.srt',
        'movie.zh.ass',
        'movie.chs.srt',
        'movie.简体.ass',
      ]);
    });

    test('大小写不敏感', () {
      final matched = subtitlesForVideo(
        videoFileName: 'Movie.mkv',
        directoryFileNames: <String>['movie.ZH.srt', 'MOVIE.srt'],
      );
      expect(matched, <String>['movie.ZH.srt', 'MOVIE.srt']);
    });

    test('保持输入顺序', () {
      final matched = subtitlesForVideo(
        videoFileName: 'ep01.mkv',
        directoryFileNames: <String>['ep01.en.srt', 'ep01.zh.srt'],
      );
      expect(matched, <String>['ep01.en.srt', 'ep01.zh.srt']);
    });

    test('前缀相同的另一部片不配', () {
      final matched = subtitlesForVideo(
        videoFileName: 'Show.mkv',
        directoryFileNames: <String>['Show2.srt', 'Shows.srt'],
      );
      expect(matched, isEmpty);
    });

    test('过长的后缀不当字幕', () {
      final matched = subtitlesForVideo(
        videoFileName: 'movie.mkv',
        directoryFileNames: <String>['movie.behind.the.scenes.srt'],
      );
      expect(matched, isEmpty);
    });

    test('空视频名返回空列表', () {
      expect(
        subtitlesForVideo(
          videoFileName: '  ',
          directoryFileNames: <String>['movie.srt'],
        ),
        isEmpty,
      );
    });
  });

  group('边界', () {
    test('空串与纯分隔符不抛异常', () {
      for (final name in <String>['', '   ', '.', '...', '-', '_-_', '.mkv']) {
        final parsed = parseMediaFileName(name);
        expect(parsed.season, isNull, reason: name);
        expect(parsed.episode, isNull, reason: name);
        expect(parsed.title.trim(), parsed.title, reason: name);
      }
      expect(parseMediaFileName('').title, '');
    });

    test('纯噪声名退回原始名而不是空标题', () {
      expect(parseMediaFileName('1080p.mkv').title, '1080p');
      expect(parseMediaFileName('BDRip').title, 'BDRip');
    });

    test('中文/日文/韩文/emoji 名不抛异常', () {
      final mixed = parseMediaFileName('【测试】日本語のタイトル 第01話 🎬.mkv');
      expect(mixed.episode, 1);
      expect(mixed.title, '日本語のタイトル 🎬');

      final korean = parseMediaFileName('한국어 제목 3화.mkv');
      expect(korean.title, isNotEmpty);

      expect(() => parseMediaFileName('🎬🎬🎬.mkv'), returnsNormally);
      expect(() => parseMediaFileName('＃全角＃'), returnsNormally);
    });

    test('超长文件名不抛异常且仍能解析集号', () {
      final long = '${'长标题' * 2000}.S01E07.1080p.mkv';
      final parsed = parseMediaFileName(long);
      expect(parsed.season, 1);
      expect(parsed.episode, 7);
      expect(parsed.title.length, greaterThan(100));
    });

    test('超长英文名与无扩展名', () {
      final long = '${'A' * 5000}.E03.mkv';
      final parsed = parseMediaFileName(long);
      expect(parsed.episode, 3);
      expect(() => parseMediaFileName('B' * 20000), returnsNormally);
    });

    test('排序在有 null 字段与怪异名字时仍是全序', () {
      final names = <String>[
        '10.mkv',
        '2.mkv',
        'Show - 3.mkv',
        'SP.mkv',
        '',
      ]..sort(_compareByName);
      expect(names, <String>[
        '2.mkv',
        'Show - 3.mkv',
        '10.mkv',
        // 两者都没有集号 → 并列最后一档，再按标题自然序（空标题排最前）。
        '',
        'SP.mkv',
      ]);
    });
  });
}
