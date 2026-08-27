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
      expect(e.isWarning, isFalse, reason: 'everything still works, including a browser');
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
        reason: 'this is the whole reason the phone is the one that has to say it',
      );
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
