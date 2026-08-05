import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source continuation supports long Small Color galleries', () {
    expect(maxSourceContinuationRequests, 500);
    expect(maxSourceContinuationRequests, greaterThan(219));
  });
}
