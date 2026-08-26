/// The pin, through a real socket, inside `flutter test`.
///
/// Every other test in this suite inspects values. This one stands up an actual TLS
/// server on loopback and drives `PinnedHttpOverrides` through a handshake, because the
/// property that matters is not "the comparison function returns false" — it is that a
/// wrong certificate is refused *by the TLS stack*, before a request body exists.
///
/// `tool/prove_pin.dart` proves the same thing more thoroughly, against two live
/// nestwatch instances and a byte-counting listener. But it needs those servers running,
/// so it cannot run in CI or from a bare `flutter test` — which meant the single
/// security property this whole app exists for was the one thing the suite never
/// checked. This closes that, at the cost of not being able to watch the wire directly:
/// instead the server records whether its request handler ever fired, which answers the
/// same question from the other end.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

/// Fingerprint of a PEM certificate, computed the way nestwatch does: SHA-256 over the
/// DER bytes. Read at runtime so regenerating the fixtures needs no edit here.
Fingerprint fingerprintOf(String pemPath) {
  final pem = File(pemPath).readAsStringSync();
  final b64 = pem
      .split('\n')
      .where((l) => !l.startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), '');
  return Fingerprint.fromBytes(sha256.convert(base64.decode(b64)).bytes);
}

void main() {
  const dir = 'test/fixtures';
  late HttpServer server;
  late Fingerprint servedPin;
  late Fingerprint otherPin;

  /// Set by the request handler. Stays false when the handshake is refused, which is the
  /// assertion that matters: no request reached the server at all.
  var handlerRan = false;

  setUp(() async {
    handlerRan = false;
    final context = SecurityContext()
      ..useCertificateChain('$dir/server.cert.pem')
      ..usePrivateKey('$dir/server.key.pem');

    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0, // any free port
      context,
    );
    server.listen((request) async {
      handlerRan = true;
      request.response
        ..statusCode = 200
        ..write('{"authenticated":false,"version":"test"}');
      await request.response.close();
    });

    servedPin = fingerprintOf('$dir/server.cert.pem');
    otherPin = fingerprintOf('$dir/impostor.cert.pem');
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  Future<String> get_(HttpClient client) async {
    final request = await client.getUrl(
      Uri.parse('https://127.0.0.1:${server.port}/session'),
    );
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  test('the fixtures are two DIFFERENT certificates', () {
    // If these ever collide the rest of the file proves nothing.
    expect(servedPin, isNot(otherPin));
  });

  test('the right certificate is admitted', () async {
    HttpOverrides.global = PinnedHttpOverrides(pin: servedPin);
    expect(await get_(HttpClient()), contains('"version":"test"'));
    expect(handlerRan, isTrue);
  });

  test(
    'a WRONG certificate is refused, and nothing reaches the server',
    () async {
      HttpOverrides.global = PinnedHttpOverrides(pin: otherPin);
      await expectLater(get_(HttpClient()), throwsA(isA<HandshakeException>()));
      // The property `prove_pin.dart` measures on the wire, asserted from the far end:
      // the request handler never ran, so no request was ever delivered.
      expect(
        handlerRan,
        isFalse,
        reason:
            'the refusal must happen during the handshake, before any request',
      );
    },
  );

  test('NO pin refuses everything', () async {
    HttpOverrides.global = PinnedHttpOverrides();
    await expectLater(get_(HttpClient()), throwsA(isA<HandshakeException>()));
    expect(handlerRan, isFalse);
  });

  // A limit of this file, found by mutation rather than by reading it:
  //
  // Flipping `withTrustedRoots: false` to `true` in PinnedHttpOverrides leaves every
  // test here passing. The fixtures are self-signed, so they fail validation under
  // either setting and `badCertificateCallback` fires either way. Reaching that trap
  // needs a certificate the platform genuinely trusts, which no test can obtain for
  // 127.0.0.1.
  //
  // The setting stays, for two reasons. It makes the callback the sole authority by
  // construction instead of by luck; and while a public CA will not issue for a private
  // address today, nothing in this code assumes the server is only ever reached by IP.
  // It is defence that cannot be tested here, which is worth saying next to the tests
  // that can.

  test('a refusal records what was presented, keyed by authority', () async {
    final overrides = PinnedHttpOverrides(pin: otherPin);
    HttpOverrides.global = overrides;
    await expectLater(get_(HttpClient()), throwsA(isA<HandshakeException>()));

    final rejection = overrides.rejectionFor('127.0.0.1:${server.port}');
    expect(rejection, isNotNull);
    expect(rejection!.observed, servedPin);
    expect(rejection.expected, otherPin);
    // A different authority must not inherit this one's answer.
    expect(overrides.rejectionFor('127.0.0.1:1'), isNull);
  });

  test('trusting the observed certificate then works', () async {
    final overrides = PinnedHttpOverrides(pin: otherPin);
    HttpOverrides.global = overrides;
    await expectLater(get_(HttpClient()), throwsA(isA<HandshakeException>()));

    // Trust-on-first-use, end to end: observe by refusing, then adopt.
    final observed = overrides
        .rejectionFor('127.0.0.1:${server.port}')!
        .observed;
    overrides.trust(observed);
    expect(await get_(HttpClient()), contains('"version":"test"'));
    expect(handlerRan, isTrue);
    // A pin change clears the record; a stale rejection must not outlive it.
    expect(overrides.rejectionFor('127.0.0.1:${server.port}'), isNull);
  });

  test('a single byte changed in the pin is enough to refuse', () async {
    final nearMiss = Fingerprint.fromBytes([...servedPin.bytes]..[31] ^= 0x01);
    HttpOverrides.global = PinnedHttpOverrides(pin: nearMiss);
    await expectLater(get_(HttpClient()), throwsA(isA<HandshakeException>()));
    expect(handlerRan, isFalse);
  });
}
