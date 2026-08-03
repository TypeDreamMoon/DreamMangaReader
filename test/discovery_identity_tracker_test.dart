import 'package:dream_manga_reader/features/discovery/manga_identity_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tracks manga identity per source until cleared', () {
    final tracker = MangaIdentityTracker();

    expect(tracker.add('misskon', 'misskon:tag:4585'), true);
    expect(tracker.add('misskon', 'misskon:tag:4585'), false);
    expect(tracker.add('other', 'misskon:tag:4585'), true);

    tracker.clear();

    expect(tracker.add('misskon', 'misskon:tag:4585'), true);
  });
}
