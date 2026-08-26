import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/ui/relative_time.dart';

void main() {
  final now = DateTime.utc(2026, 8, 26, 12, 0, 0);
  String at(Duration back) => ago(now.subtract(back), now: now);

  group('ago rounds down, and says so in words', () {
    test('under a minute is not a number', () {
      expect(at(Duration.zero), 'just now');
      expect(at(const Duration(seconds: 59)), 'just now');
    });

    test('each unit changes exactly on its boundary', () {
      expect(at(const Duration(seconds: 60)), '1 min ago');
      expect(at(const Duration(minutes: 59)), '59 min ago');
      expect(at(const Duration(minutes: 60)), '1 h ago');
      expect(at(const Duration(hours: 23)), '23 h ago');
      expect(at(const Duration(hours: 24)), '1 d ago');
    });

    test('a clock that has slipped backwards reads as just now', () {
      // Phones correct their clocks, and a timestamp from a PC can land in this phone's
      // future. A negative difference must not print "-1 min ago" next to a child's
      // request; the least wrong thing to say is that it is current.
      expect(at(const Duration(minutes: -5)), 'just now');
    });
  });
}
