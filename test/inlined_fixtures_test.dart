/// The integration test's inlined certificates must still be the fixture files.
///
/// `integration_test/inlined_fixtures.dart` holds copies, because a test running inside
/// the app sandbox on a device cannot read `test/fixtures/` — and declaring those files
/// as Flutter assets would ship a private key inside the real app, which is a worse trade
/// than a copy.
///
/// A copy that can drift silently is the defect this repo keeps finding in itself. This is
/// the same answer as `tool/check_golden.sh`: keep the copy, and compare it somewhere that
/// runs often. Here that is every ordinary `flutter test`, on the host, where both the
/// file and the constant are readable.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../integration_test/inlined_fixtures.dart';

void main() {
  String fixture(String name) =>
      File('test/fixtures/$name').readAsStringSync().trim();

  const pairs = {
    'server.cert.pem': serverCertPem,
    'server.key.pem': serverKeyPem,
    'impostor.cert.pem': impostorCertPem,
  };

  for (final entry in pairs.entries) {
    test('${entry.key} is inlined exactly', () {
      expect(
        File('test/fixtures/${entry.key}').existsSync(),
        isTrue,
        reason: 'the fixture moved; nothing was compared',
      );
      expect(
        entry.value.trim(),
        fixture(entry.key),
        reason:
            'integration_test/inlined_fixtures.dart has drifted from the file it '
            'copies. Regenerate it rather than editing by hand — the iOS pin proof '
            'would otherwise be testing a certificate no other test uses.',
      );
    });
  }

  test('the two certificates inlined are actually different', () {
    // The same guard pinning_socket_test makes about the files. A copy step that
    // duplicated one PEM into both slots would leave every refusal test vacuous.
    expect(serverCertPem, isNot(impostorCertPem));
  });
}
