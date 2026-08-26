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
      expect(text.toLowerCase(), isNot(contains('verified')));
      expect(text.toLowerCase(), isNot(contains('safe to')));
      expect(text.toLowerCase(), isNot(contains('this is expected')));
    });

    test('does not lead with the comfortable explanation', () {
      // Certificates change rarely, and deliberately so: `install` reuses the existing
      // one while its addresses still cover the PC, because reissuing on every routine
      // upgrade "trains the parent to click through warnings without looking — the exact
      // habit the fingerprint check depends on them not having" (nestwatch
      // src/install.rs). An earlier version of this copy opened with "if you just
      // re-ran nestwatch install, this is expected", which tilts a parent toward the
      // innocent reading at the moment that costs most.
      final text = explainMismatch(
        rejectionWithCertAge(const Duration(hours: 1)),
      );
      final firstLine = text.split('\n').firstWhere((l) => l.trim().isNotEmpty);
      expect(
        firstLine.toLowerCase(),
        isNot(contains('if you just')),
        reason: 'the opening sentence must not be a reassurance',
      );

      // The two narrow innocent causes are named — but as the exceptions they are.
      expect(text, contains('--new-cert'));
      expect(text.toLowerCase(), contains('address'));
      expect(text.toLowerCase(), contains('nothing else should'));
    });

    test('never suggests re-scanning a QR to clear the warning', () {
      // Re-scanning adopts whatever is being presented. It is the one action that turns
      // a refusal into silent trust, so the copy must not offer it as a remedy.
      for (final age in [
        const Duration(hours: 1),
        const Duration(days: 30),
        const Duration(hours: -5),
      ]) {
        final text = explainMismatch(rejectionWithCertAge(age)).toLowerCase();
        expect(text, isNot(contains('re-scan the pairing qr')), reason: '$age');
      }
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
