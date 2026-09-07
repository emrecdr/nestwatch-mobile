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

  group('how recently a signed-in device was about', () {
    // `last_seen` is not an instant the server recorded. nestwatch derives it as
    // `expires - SESSION_IDLE_DAYS`, and the sliding expiry only saves every five days, so
    // the figure is accurate to about a working week. Their comment sets the ceiling:
    // "'Active this week' is what the card can honestly say".
    //
    // Running it through `ago` would print "3 d ago" off a number that cannot support a
    // day — a true-looking figure at a precision nobody measured, which is the same defect
    // as rendering `used_mins: 0` with no enforcer age beside it.
    final now = DateTime.utc(2026, 9, 7, 12);
    String at(Duration back) => lastSeenPhrase(now.subtract(back), now: now);

    test('within the week', () {
      expect(at(Duration.zero), 'Active this week');
      expect(at(const Duration(days: 6, hours: 23)), 'Active this week');
    });

    test('the week before', () {
      expect(at(const Duration(days: 7)), 'Active last week');
      expect(at(const Duration(days: 13)), 'Active last week');
    });

    test('earlier in the month', () {
      expect(at(const Duration(days: 14)), 'Active this month');
      expect(at(const Duration(days: 30)), 'Active this month');
    });

    test('and the one that tells a live phone from one retired in August', () {
      expect(at(const Duration(days: 31)), 'Not used in over a month');
      expect(at(const Duration(days: 400)), 'Not used in over a month');
    });

    test('a time slightly in the future reads as current, not as an error', () {
      // Reachable without anything being wrong: `expires` moves forward on a refresh, so a
      // session saved moments ago can derive a `last_seen` a hair ahead of a phone clock
      // that disagrees by seconds.
      expect(at(const Duration(days: -1)), 'Active this week');
    });

    test('it is not `ago` wearing a different name', () {
      // The whole point. If these ever agree, somebody has re-pointed one at the other and
      // the precision claim is gone.
      final week = now.subtract(const Duration(days: 3));
      expect(lastSeenPhrase(week, now: now), isNot(ago(week, now: now)));
    });
  });
}
