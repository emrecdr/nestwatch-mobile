import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pin_mismatch_message.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

PinRejection rejectionWithCertAge(Duration age) {
  final at = DateTime.utc(2026, 8, 26, 12);
  return PinRejection(
    host: '192.168.0.78',
    port: 8443,
    observed: Fingerprint.fromBytes(sha256.convert('observed'.codeUnits).bytes),
    expected: Fingerprint.fromBytes(sha256.convert('expected'.codeUnits).bytes),
    notBefore: at.subtract(age),
    at: at,
  );
}

void main() {
  group('classifyMismatch', () {
    test('a freshly minted certificate is consistent with a reinstall', () {
      // nestwatch backdates not_before by exactly one hour (src/cert.rs) so clock skew
      // cannot make a new cert read as "not yet valid". A cert straight out of
      // `install` therefore presents as ~1h old, not 0.
      expect(
        classifyMismatch(rejectionWithCertAge(const Duration(hours: 1))).name,
        MismatchStory.consistentWithReinstall.name,
      );
      expect(
        classifyMismatch(rejectionWithCertAge(const Duration(hours: 23))).name,
        MismatchStory.consistentWithReinstall.name,
      );
    });

    test('an old certificate rules the reinstall story out', () {
      expect(
        classifyMismatch(rejectionWithCertAge(const Duration(days: 30))).name,
        MismatchStory.inconsistentWithReinstall.name,
      );
    });

    test('a certificate starting in the future is not reasoned about', () {
      expect(
        classifyMismatch(rejectionWithCertAge(const Duration(hours: -5))).name,
        MismatchStory.unknown.name,
      );
    });

    test('the boundary is the documented window', () {
      expect(reinstallPlausibleWindow, const Duration(hours: 24));
      expect(
        classifyMismatch(rejectionWithCertAge(reinstallPlausibleWindow)).name,
        MismatchStory.consistentWithReinstall.name,
      );
      expect(
        classifyMismatch(
          rejectionWithCertAge(
            reinstallPlausibleWindow + const Duration(minutes: 1),
          ),
        ).name,
        MismatchStory.inconsistentWithReinstall.name,
      );
    });
  });

  group('explainMismatch', () {
    test('never claims to know which story is true', () {
      // A fresh certificate is equally consistent with an attacker who just minted one
      // — and who can copy nestwatch's one-hour backdate exactly. The copy must not
      // present freshness as reassurance.
      final text = explainMismatch(
        rejectionWithCertAge(const Duration(hours: 1)),
      );
      expect(text, contains('If you just re-ran'));
      expect(text, contains('If you did not'));
      expect(text.toLowerCase(), isNot(contains('verified')));
      expect(text.toLowerCase(), isNot(contains('safe to')));
    });

    test('always sends the parent to the PC itself', () {
      for (final age in [
        const Duration(hours: 1),
        const Duration(days: 30),
        const Duration(hours: -5),
      ]) {
        expect(
          explainMismatch(rejectionWithCertAge(age)),
          contains('nestwatch fingerprint'),
          reason: '$age',
        );
      }
    });

    test('says the refusal happened before anything was sent', () {
      // The property step 2 proved on the wire, stated where a parent can read it.
      expect(
        explainMismatch(rejectionWithCertAge(const Duration(hours: 1))),
        contains('before anything was sent'),
      );
    });
  });
}
