import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';

void main() {
  final fp = Fingerprint.fromBytes(sha256.convert('cert'.codeUnits).bytes);

  Map<String, dynamic> json({String provenance = 'verifiedFromQrCode'}) => {
    'host': '192.168.0.78',
    'port': 8443,
    'fingerprint': fp.toString(),
    'provenance': provenance,
    'pairedAt': '2026-08-26T10:00:00.000Z',
  };

  group('ServerIdentity round-trips', () {
    test('both provenances survive', () {
      for (final p in PinProvenance.values) {
        final back = ServerIdentity.fromJson(
          ServerIdentity(
            host: 'h',
            port: 1,
            fingerprint: fp,
            provenance: p,
            pairedAt: DateTime.utc(2026),
          ).toJson(),
        );
        expect(back.provenance, p);
        expect(back.fingerprint, fp);
      }
    });
  });

  group('an unrecognised provenance', () {
    // The failure this guards against is silent and one-directional: a storage-format
    // change, a downgrade, a hand-edited file, and trust-on-first-use is quietly
    // relabelled as verified. The app would then stop telling the parent that their
    // connection was only ever as good as a fingerprint they compared by eye.
    test('reads as the WEAKER of the two, never the stronger', () {
      for (final unknown in [
        '',
        'verified',
        'VERIFIEDFROMQRCODE',
        'v2',
        'null',
      ]) {
        final identity = ServerIdentity.fromJson(json(provenance: unknown));
        expect(
          identity.provenance,
          PinProvenance.trustedOnFirstUse,
          reason: '"$unknown" must not be read as verified',
        );
        expect(identity.provenance.isVerified, isFalse);
      }
    });

    test('a missing provenance key does too', () {
      final withoutKey = json()..remove('provenance');
      expect(
        ServerIdentity.fromJson(withoutKey).provenance,
        PinProvenance.trustedOnFirstUse,
      );
    });

    test('only the exact stored name counts as verified', () {
      expect(
        ServerIdentity.fromJson(
          json(provenance: 'verifiedFromQrCode'),
        ).provenance.isVerified,
        isTrue,
      );
    });
  });
}
