/// The one spoken string in this app that could become false by itself.
///
/// Every other accessible string is static or bound to a value that does not change while
/// it is on screen — the two `Semantics` labels on Approve and Deny carry the request's
/// minutes, and the six tooltips are fixed words. The screenshot's label was the exception,
/// and the exception is the whole reason this file exists.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/ui/frame_label.dart';
import 'package:nestwatch_mobile/src/ui/relative_time.dart';

void main() {
  group('the label does not go stale', () {
    // The defect, stated as a test. `ago()` is computed once at build; this screen is the
    // only one whose poller can be stopped while its content stays up, so nothing rebuilds
    // and the answer freezes. An absolute time makes no claim about *now*, so there is
    // nothing to freeze.
    test('the same frame reads the same an hour later', () {
      final at = DateTime(2026, 9, 2, 14, 32, 7);
      final spokenWhenFresh = frameLabel(at);

      // Simulating the passage of time is exactly what this must be immune to: the label
      // is a pure function of the frame's own timestamp and nothing else.
      final spokenMuchLater = frameLabel(at);
      expect(spokenMuchLater, spokenWhenFresh);
      expect(spokenWhenFresh, contains('14:32:07'));
    });

    test(
      'and `ago` on the same instant does not — which is why it was wrong here',
      () {
        // The control. Without it this file asserts only that a constant is constant, and
        // would pass just as well against the code that had the bug.
        final at = DateTime(2026, 9, 2, 14, 32, 7);
        expect(ago(at, now: at), 'just now');
        expect(ago(at, now: at.add(const Duration(hours: 1))), '1 h ago');
        expect(
          ago(at, now: at),
          isNot(ago(at, now: at.add(const Duration(hours: 1)))),
          reason:
              'a relative time is a claim about now, and this screen stops rebuilding',
        );
      },
    );
  });

  group('the spoken and the visible answer agree', () {
    test('the label carries exactly the clock the visible line shows', () {
      final at = DateTime(2026, 9, 2, 9, 5, 3);
      // The visible line renders 'Frame from ${frameClock(at)}.', so containing the same
      // string is the assertion that the two surfaces cannot drift apart.
      expect(frameLabel(at), contains(frameClock(at)));
    });

    test('zero-padded, so 9:05:03 is not read as 9:5:3', () {
      expect(frameClock(DateTime(2026, 9, 2, 9, 5, 3)), '09:05:03');
      expect(frameClock(DateTime(2026, 9, 2, 23, 59, 59)), '23:59:59');
      expect(frameClock(DateTime(2026, 9, 2, 0, 0, 0)), '00:00:00');
    });
  });

  group('before the first frame', () {
    test('says less rather than saying "taken at" about nothing', () {
      expect(frameLabel(null), 'A picture of the screen on that PC.');
      expect(frameLabel(null), isNot(contains('taken at')));
    });
  });
}
