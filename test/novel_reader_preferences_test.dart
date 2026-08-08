import 'package:dream_manga_reader/app/novel_library_store.dart';
import 'package:dream_manga_reader/core/novel/models.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_font_store.dart';
import 'package:dream_manga_reader/core/novel/reader/novel_reader_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reader paging models are stable pure-Dart value objects', () {
    const viewport = NovelViewport(
      width: 1080,
      height: 1920,
      devicePixelRatio: 3,
    );
    const key = NovelPageKey(
      chapterId: 'c1',
      pageIndex: 2,
      layoutFingerprint: 'layout-a',
    );
    const sameKey = NovelPageKey(
      chapterId: 'c1',
      pageIndex: 2,
      layoutFingerprint: 'layout-a',
    );
    const metrics = NovelPageMetrics(
      pageCount: 8,
      currentPageIndex: 2,
      viewport: viewport,
      layoutFingerprint: 'layout-a',
    );
    final frame = NovelPageFrame(
      key: key,
      viewport: viewport,
      bytes: List<int>.filled(16, 0),
    );
    const selection = NovelSelection(
      text: 'selected',
      start: NovelLocator(chapterId: 'c1', blockId: 'p1', charOffset: 3),
      end: NovelLocator(chapterId: 'c1', blockId: 'p1', charOffset: 11),
    );

    expect(key, sameKey);
    expect(
      viewport,
      const NovelViewport(width: 1080, height: 1920, devicePixelRatio: 3),
    );
    expect(
      metrics,
      NovelPageMetrics(
        pageCount: 8,
        currentPageIndex: 2,
        viewport: viewport,
        layoutFingerprint: 'layout-a',
      ),
    );
    expect(frame.byteSize, 16);
    expect(
      selection,
      NovelSelection(
        text: 'selected',
        start: NovelLocator(
          chapterId: 'c1',
          blockId: 'p1',
          charOffset: 3,
        ),
        end: NovelLocator(
          chapterId: 'c1',
          blockId: 'p1',
          charOffset: 11,
        ),
      ),
    );
    expect(() => frame.bytes.add(1), throwsUnsupportedError);
    expect(NovelReaderCommand.values, contains(NovelReaderCommand.next));
  });

  test('legacy paged preferences migrate to schema v2 defaults', () {
    final preferences = NovelReaderPreferences.fromJson({
      'mode': 'paged',
      'fontFamily': 'serif',
      'fontSize': 20,
      'lineHeight': 1.8,
      'paragraphSpacing': 14,
      'horizontalMargin': 28,
      'theme': 'sepia',
      'keepScreenOn': false,
      'toolbarAutoHideSeconds': 7,
    });

    expect(preferences.turnMode, NovelPageTurnMode.curl);
    expect(preferences.mode, NovelReaderMode.paged);
    expect(preferences.fontFamily, NovelFontIds.notoSerifSc);
    expect(preferences.fontSize, 20);
    expect(preferences.lineHeight, 1.8);
    expect(preferences.paragraphSpacing, 14);
    expect(preferences.horizontalMargin, 28);
    expect(preferences.theme, NovelReaderTheme.eyeCare);
    expect(preferences.keepScreenOn, isFalse);
    expect(preferences.toolbarAutoHideSeconds, 7);
    expect(preferences.topMargin, 16);
    expect(preferences.bottomMargin, 20);
    expect(preferences.firstLineIndent, 2);
    expect(preferences.textAlignment, NovelTextAlignment.justify);
    expect(preferences.showChapterName, isTrue);
    expect(preferences.showPageNumber, isTrue);
    expect(preferences.showBookProgress, isTrue);
    expect(preferences.showTime, isTrue);
    expect(preferences.showBattery, isTrue);
    expect(preferences.singleHandNext, isFalse);
  });

  test('legacy scroll preferences migrate to scroll turn mode', () {
    expect(
      NovelReaderPreferences.fromJson(const {'mode': 'scroll'}).turnMode,
      NovelPageTurnMode.scroll,
    );
  });

  test('schema v2 preferences round trip without legacy keys', () {
    const preferences = NovelReaderPreferences(
      turnMode: NovelPageTurnMode.cover,
      fontFamily: NovelFontIds.lxgwWenKai,
      fontSize: 24,
      lineHeight: 2,
      paragraphSpacing: 12,
      horizontalMargin: 30,
      topMargin: 18,
      bottomMargin: 24,
      firstLineIndent: 1.5,
      textAlignment: NovelTextAlignment.start,
      theme: NovelReaderTheme.black,
      keepScreenOn: false,
      toolbarAutoHideSeconds: 6,
      showChapterName: false,
      showPageNumber: false,
      showBookProgress: false,
      showTime: false,
      showBattery: false,
      singleHandNext: true,
      brightness: 1.15,
    );

    final json = preferences.toJson();
    final restored = NovelReaderPreferences.fromJson(json);

    expect(json['schema'], 2);
    expect(json['turnMode'], 'cover');
    expect(json, isNot(contains('mode')));
    expect(restored.turnMode, NovelPageTurnMode.cover);
    expect(restored.fontFamily, NovelFontIds.lxgwWenKai);
    expect(restored.fontSize, 24);
    expect(restored.lineHeight, 2);
    expect(restored.paragraphSpacing, 12);
    expect(restored.horizontalMargin, 30);
    expect(restored.topMargin, 18);
    expect(restored.bottomMargin, 24);
    expect(restored.firstLineIndent, 1.5);
    expect(restored.textAlignment, NovelTextAlignment.start);
    expect(restored.theme, NovelReaderTheme.black);
    expect(restored.keepScreenOn, isFalse);
    expect(restored.toolbarAutoHideSeconds, 6);
    expect(restored.showChapterName, isFalse);
    expect(restored.showPageNumber, isFalse);
    expect(restored.showBookProgress, isFalse);
    expect(restored.showTime, isFalse);
    expect(restored.showBattery, isFalse);
    expect(restored.singleHandNext, isTrue);
    expect(restored.brightness, 1.15);
  });

  test('deserialization clamps every numeric preference', () {
    final low = NovelReaderPreferences.fromJson(const {
      'fontSize': -1,
      'lineHeight': -1,
      'paragraphSpacing': -1,
      'horizontalMargin': -1,
      'topMargin': -1,
      'bottomMargin': -1,
      'firstLineIndent': -1,
      'toolbarAutoHideSeconds': -1,
      'brightness': -1,
    });
    final high = NovelReaderPreferences.fromJson(const {
      'fontSize': 999,
      'lineHeight': 999,
      'paragraphSpacing': 999,
      'horizontalMargin': 999,
      'topMargin': 999,
      'bottomMargin': 999,
      'firstLineIndent': 999,
      'toolbarAutoHideSeconds': 999,
      'brightness': 999,
    });

    expect(low.fontSize, 12);
    expect(low.lineHeight, 1.2);
    expect(low.paragraphSpacing, 0);
    expect(low.horizontalMargin, 8);
    expect(low.topMargin, 0);
    expect(low.bottomMargin, 0);
    expect(low.firstLineIndent, 0);
    expect(low.toolbarAutoHideSeconds, 0);
    expect(low.brightness, .6);
    expect(high.fontSize, 32);
    expect(high.lineHeight, 2.4);
    expect(high.paragraphSpacing, 30);
    expect(high.horizontalMargin, 56);
    expect(high.topMargin, 96);
    expect(high.bottomMargin, 96);
    expect(high.firstLineIndent, 4);
    expect(high.toolbarAutoHideSeconds, 10);
    expect(high.brightness, 1.4);
  });

  test('non-finite numeric preferences fall back to defaults', () {
    final preferences = NovelReaderPreferences.fromJson({
      'fontSize': double.infinity,
      'toolbarAutoHideSeconds': double.nan,
    });

    expect(preferences.fontSize, 18);
    expect(preferences.toolbarAutoHideSeconds, 4);
  });
}
