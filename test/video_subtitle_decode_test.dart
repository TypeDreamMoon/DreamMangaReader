import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// `handleVideo` 里 `subtitles` 字段的解码。源脚本是外部写的,给什么都得接得住。
void main() {
  test('缺字段 / 给错类型都当没有字幕', () {
    expect(ScriptSource.decodeSubtitles(null), isEmpty);
    expect(ScriptSource.decodeSubtitles('zh.vtt'), isEmpty);
    expect(ScriptSource.decodeSubtitles(const {'url': 'zh.vtt'}), isEmpty);
    expect(ScriptSource.decodeSubtitles(const []), isEmpty);
  });

  test('没有 url 的条目直接丢掉', () {
    final decoded = ScriptSource.decodeSubtitles(const [
      {'label': '没链接'},
      {'url': ''},
      {'url': 'https://cdn.example.test/zh.vtt', 'label': '简体中文'},
    ]);

    expect(decoded, hasLength(1));
    expect(decoded.single.url, 'https://cdn.example.test/zh.vtt');
    expect(decoded.single.label, '简体中文');
  });

  test('label / language 可缺,url 在就收', () {
    final decoded = ScriptSource.decodeSubtitles(const [
      {'url': 'https://cdn.example.test/a.srt'},
      {
        'url': 'https://cdn.example.test/b.ass',
        'label': '日本語',
        'language': 'ja',
      },
    ]);

    expect(decoded.map((s) => s.label), ['', '日本語']);
    expect(decoded.map((s) => s.language), [null, 'ja']);
  });
}
