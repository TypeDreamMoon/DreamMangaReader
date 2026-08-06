import 'package:dream_manga_reader/features/anime/playback/quality_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _levels = [
  QualityLevel(id: '360p', bandwidth: 500000),
  QualityLevel(id: '720p', bandwidth: 1000000),
  QualityLevel(id: '1080p', bandwidth: 2000000),
];

void main() {
  late DateTime now;
  late QualityPolicy policy;

  setUp(() {
    now = DateTime.utc(2026, 8, 5);
    policy = QualityPolicy(levels: _levels, now: () => now);
  });

  test('starts in the middle instead of the highest quality', () {
    expect(policy.selectInitial().id, '720p');
  });

  test('low throughput lowers one level', () {
    policy.selectInitial();

    final decision = policy.recordThroughput(1100000);

    expect(decision?.id, '360p');
  });

  test('two stalls inside thirty seconds lower one level', () {
    policy.selectInitial();
    expect(policy.recordStall(), isNull);
    now = now.add(const Duration(seconds: 29));

    expect(policy.recordStall()?.id, '360p');
  });

  test('upgrades only after stable throughput and cooldown', () {
    policy.selectInitial();
    policy.recordThroughput(100000); // drop to 360p at time zero
    now = now.add(const Duration(seconds: 89));
    expect(policy.recordStableThroughput(1900000), isNull);
    now = now.add(const Duration(seconds: 1));

    expect(policy.recordStableThroughput(1900000)?.id, '720p');
  });

  test('manual quality lock blocks automatic changes', () {
    policy.selectManual('1080p');

    expect(policy.recordThroughput(1000), isNull);
    expect(policy.recordStall(), isNull);
    now = now.add(const Duration(seconds: 30));
    expect(policy.recordStall(), isNull);
    expect(policy.current.id, '1080p');
  });
}
