/// The boundaries of the expiry warning, and the injected clock that makes them reachable.
///
/// A real certificate is 825 days long, so without [now] the only branch a test could
/// reach is whichever one today happens to fall in — and the other two would be written
/// but never run. Same reason `ago` and `LoginLimits.lockoutInWords` take one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/pinning/certificate_expiry.dart';

void main() {
  final now = DateTime(2026, 8, 27, 12);
  CertificateExpiry? at(int daysFromNow) =>
      CertificateExpiry.of(now.add(Duration(days: daysFromNow)), now: now);

  group('the three lives of a certificate', () {
    test('a fresh one says nothing', () {
      final e = at(400)!;
      expect(e.life, CertificateLife.healthy);
      expect(e.message, isNull);
      expect(e.isWarning, isFalse);
    });

    test('inside the window it explains, without alarm', () {
      final e = at(12)!;
      expect(e.life, CertificateLife.expiringSoon);
      expect(
        e.isWarning,
        isFalse,
        reason: 'everything still works, including a browser',
      );
      expect(e.message, contains('12 days'));
      expect(
        e.message,
        contains('every other device'),
        reason: 'the cost of renewing is the part worth scheduling around',
      );
    });

    test('past it, the sentence explains the browser rather than the phone', () {
      final e = at(-3)!;
      expect(e.life, CertificateLife.expired);
      expect(e.isWarning, isTrue);
      expect(e.message, contains('3 days ago'));
      expect(
        e.message,
        contains('not because the PC is broken'),
        reason:
            'this is the whole reason the phone is the one that has to say it',
      );
    });
  });

  group('the hours after expiry, which is when it matters most', () {
    // The defect this group exists for. `Duration.inDays` truncates toward zero, so a
    // certificate that lapsed five hours ago gave `inDays == 0` — not less than zero —
    // and read as *expiring* for a full 24 hours. It said "expires in 0 days", and since
    // only the expired verdict raised a strip, it said it silently. That day is exactly
    // when the browser stops working and a parent starts looking for the reason.
    for (final hours in [1, 5, 12, 23]) {
      test('expired ${hours}h ago is expired, not expiring', () {
        final e = CertificateExpiry.of(
          now.subtract(Duration(hours: hours)),
          now: now,
        )!;
        expect(e.life, CertificateLife.expired);
        expect(e.isWarning, isTrue, reason: 'and it must raise a strip');
      });
    }

    test('and it does not say "0 days ago"', () {
      final e = CertificateExpiry.of(
        now.subtract(const Duration(hours: 5)),
        now: now,
      )!;
      expect(e.message, contains('expired today'));
      expect(e.message, isNot(contains('0 day')));
    });

    test('one minute before expiry is still expiring, not expired', () {
      final e = CertificateExpiry.of(
        now.add(const Duration(minutes: 1)),
        now: now,
      )!;
      expect(e.life, CertificateLife.expiringSoon);
    });
  });

  group('the warning has a surface before it is too late', () {
    // The 30-day verdict used to render only in the identity dialog, behind an app-bar
    // icon whose tooltip is about pairing provenance — repeating, one level up, the
    // failure this feature exists to fix.
    test('inside the last week it earns a strip', () {
      expect(at(strippedWithinDays)!.isWarning, isTrue);
      expect(at(1)!.isWarning, isTrue);
    });

    test('but not for the whole month — a permanent band stops being read', () {
      expect(at(strippedWithinDays + 1)!.isWarning, isFalse);
      expect(at(renewWarnDays)!.isWarning, isFalse);
    });

    test('days 8 to 30 still say something, just not on every screen', () {
      expect(at(renewWarnDays)!.message, isNotNull);
      expect(at(renewWarnDays)!.life, CertificateLife.expiringSoon);
    });
  });

  group('the boundary is nestwatch\'s, not one invented here', () {
    test('exactly at the threshold warns', () {
      expect(at(renewWarnDays)!.life, CertificateLife.expiringSoon);
    });

    test('one day outside it does not', () {
      expect(at(renewWarnDays + 1)!.life, CertificateLife.healthy);
    });

    test('the threshold mirrors nestwatch RENEW_WARN_DAYS', () {
      // Pinned so a change here has to be deliberate. tool/check_golden.sh is what
      // checks it still equals the value on the other side.
      expect(renewWarnDays, 30);
    });
  });

  group('singulars, because a parent reads these', () {
    test('one day left', () => expect(at(1)!.message, contains('1 day.')));
    test('one day ago', () => expect(at(-1)!.message, contains('1 day ago')));
  });

  test('no handshake yet is silence, not a third outcome', () {
    // Unlike the version check, a null here means "not asked yet" rather than "would not
    // say" — and it answers itself on the first request.
    expect(CertificateExpiry.of(null), isNull);
  });
}
