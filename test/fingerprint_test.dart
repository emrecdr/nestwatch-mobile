import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';

void main() {
  group('Fingerprint.parse', () {
    // The same known answer nestwatch pins its own formatter against
    // (src/cert.rs, fingerprint_matches_the_nist_known_answer): FIPS 180-4 B.1,
    // SHA-256("abc"). If the two ever disagree on format, this fails here first.
    const nistAbc =
        'BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:'
        'B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD';

    test('round-trips nestwatch\'s AB:CD: format byte for byte', () {
      expect(Fingerprint.parse(nistAbc).toString(), nistAbc);
    });

    test('agrees with sha256 over the same bytes', () {
      final computed = Fingerprint.fromBytes(
        sha256.convert('abc'.codeUnits).bytes,
      );
      expect(computed.toString(), nistAbc);
      expect(computed, Fingerprint.parse(nistAbc));
    });

    test('tolerates the manglings a fingerprint arrives with', () {
      // Retyped in lowercase, pasted with a trailing newline, wrapped across lines.
      expect(Fingerprint.parse(nistAbc.toLowerCase()).toString(), nistAbc);
      expect(Fingerprint.parse('$nistAbc\n').toString(), nistAbc);
      expect(
        Fingerprint.parse(nistAbc.replaceFirst(':', ':\n  ')).toString(),
        nistAbc,
      );
    });

    test('rejects a truncated pin rather than pinning on a prefix', () {
      // A short pin is a weaker pin that still looks like one, so this must throw
      // rather than pad, pass, or compare what it got.
      expect(
        () => Fingerprint.parse(nistAbc.substring(0, 40)),
        throwsFormatException,
      );
      expect(() => Fingerprint.parse(''), throwsFormatException);
    });

    test('rejects non-hex', () {
      expect(
        () => Fingerprint.parse(nistAbc.replaceFirst('BA', 'ZZ')),
        throwsFormatException,
      );
    });
  });

  group('Fingerprint.matches', () {
    final a = Fingerprint.fromBytes(sha256.convert('abc'.codeUnits).bytes);
    final b = Fingerprint.fromBytes(sha256.convert('abd'.codeUnits).bytes);

    test(
      'accepts an identical digest',
      () => expect(a.matches(a.bytes), isTrue),
    );
    test('rejects a different one', () => expect(a.matches(b.bytes), isFalse));

    test('rejects a length mismatch instead of comparing a prefix', () {
      expect(a.matches(a.bytes.sublist(0, 31)), isFalse);
      expect(a.matches([...a.bytes, 0]), isFalse);
    });

    test('differs in the last byte only — still rejected', () {
      final nearMiss = [...a.bytes]..[31] ^= 0x01;
      expect(a.matches(nearMiss), isFalse);
    });
  });
}
