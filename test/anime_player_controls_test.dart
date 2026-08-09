import 'package:dream_manga_reader/l10n/app_localizations.dart';
import 'package:dream_manga_reader/features/anime/anime_player_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('drag pauses first and commits one seek with prior play state',
      (tester) async {
    final events = <String>[];
    Duration? committed;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: AnimePlayerControls(
          position: const Duration(minutes: 2),
          duration: const Duration(minutes: 10),
          playing: true,
          buffering: false,
          onPlayPause: () {},
          onScrubStart: (wasPlaying) => events.add('start:$wasPlaying'),
          onSeek: (target, resumeAfterSeek) {
            events.add('seek:$resumeAfterSeek');
            committed = target;
          },
          onOpenPanel: () {},
          onFullscreen: () {},
        ),
      ),
    ));

    await tester.drag(find.byType(Slider), const Offset(180, 0));
    await tester.pump();

    expect(events, ['start:true', 'seek:true']);
    expect(committed, isNotNull);
    expect(committed!, greaterThan(const Duration(minutes: 2)));
  });

  testWidgets('dragging while paused never requests resume', (tester) async {
    bool? resumeAfterSeek;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: AnimePlayerControls(
          position: const Duration(minutes: 4),
          duration: const Duration(minutes: 10),
          playing: false,
          buffering: false,
          onPlayPause: () {},
          onScrubStart: (_) {},
          onSeek: (_, resume) => resumeAfterSeek = resume,
          onOpenPanel: () {},
          onFullscreen: () {},
        ),
      ),
    ));

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();

    expect(resumeAfterSeek, isFalse);
  });

  testWidgets('short seek clamps to the media boundaries', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: AnimePlayerControls(
          position: const Duration(seconds: 5),
          duration: const Duration(seconds: 20),
          playing: false,
          buffering: false,
          onPlayPause: () {},
          onScrubStart: (_) {},
          onSeek: (target, _) => seeks.add(target),
          onOpenPanel: () {},
          onFullscreen: () {},
        ),
      ),
    ));

    await tester.tap(find.byTooltip('后退 10 秒'));
    await tester.tap(find.byTooltip('前进 10 秒'));

    expect(seeks, [Duration.zero, const Duration(seconds: 15)]);
  });
}
