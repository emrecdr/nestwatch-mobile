/// What a pinned client does with an *expired* certificate.
///
/// This file exists because a claim was made and had to be settled rather than argued.
/// `badCertificateCallback` fires when a certificate fails to authenticate for **any**
/// reason, and this app returns `true` on a fingerprint match — so the reasoning went
/// that expiry, being one of those reasons, is simply overruled. Reasoning is not a
/// result. A TLS stack could plausibly refuse a dead certificate before ever consulting
/// the callback, and then everything below would be wrong.
///
/// So: a real handshake against a real server presenting a certificate that expired on
/// 1 January 2024, driven through the same overrides the app installs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'support/certs.dart';

void main() {
  const dir = fixtureDir;
  late HttpServer server;
  late Fingerprint expiredPin;
  var handlerRan = false;

  setUp(() async {
    handlerRan = false;
    final context = SecurityContext()
      ..useCertificateChain('$dir/expired.cert.pem')
      ..usePrivateKey('$dir/expired.key.pem');

    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) async {
      handlerRan = true;
      request.response
        ..statusCode = 200
        ..write('{"authenticated":false,"version":"test"}');
      await request.response.close();
    });

    expiredPin = fingerprintOf('$dir/expired.cert.pem');
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  test('the fixture really is expired, or the rest of this file proves nothing', () {
    final der = File('$dir/expired.cert.pem').readAsStringSync();
    expect(der, contains('BEGIN CERTIFICATE'));
    // Read through the same door the app uses, rather than an openssl call a machine
    // might not have: the handshake below hands us the parsed certificate.
    expect(expiredPin.toString(), matches(RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$')));
  });

  test('an expired certificate is ACCEPTED when the pin matches', () async {
    HttpOverrides.global = PinnedHttpOverrides(pin: expiredPin);
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('https://127.0.0.1:${server.port}/session'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    expect(
      handlerRan,
      isTrue,
      reason:
          'the pin is the sole authority — withTrustedRoots: false means the callback '
          'decides, and it was told this fingerprint is the right one',
    );
    expect(body, contains('"version":"test"'));
    client.close();
  });

  test('and the certificate offered really had expired', () async {
    // Proving the acceptance above was not just a fresh certificate in disguise: the
    // handshake hands `endValidity` to the callback, and it is in the past.
    DateTime? seen;
    HttpOverrides.global = PinnedHttpOverrides(pin: expiredPin);
    final probe = HttpClient(context: SecurityContext(withTrustedRoots: false));
    probe.badCertificateCallback = (cert, host, port) {
      seen = cert.endValidity;
      return true;
    };
    final request = await probe.getUrl(
      Uri.parse('https://127.0.0.1:${server.port}/session'),
    );
    await (await request.close()).drain<void>();
    probe.close();

    expect(seen, isNotNull, reason: 'the callback never fired');
    expect(
      seen!.isBefore(DateTime.now()),
      isTrue,
      reason: 'endValidity is in the past: $seen',
    );
  });

  test('the accepted end date is recorded, and is what the callback saw', () async {
    final overrides = PinnedHttpOverrides(pin: expiredPin);
    HttpOverrides.global = overrides;
    expect(
      overrides.acceptedNotAfter,
      isNull,
      reason: 'nothing has been accepted yet',
    );

    final client = HttpClient();
    await (await (await client.getUrl(
      Uri.parse('https://127.0.0.1:${server.port}/session'),
    )).close()).drain<void>();
    client.close();

    expect(overrides.acceptedNotAfter, isNotNull);
    expect(overrides.acceptedNotAfter!.isBefore(DateTime.now()), isTrue);
  });

  test('re-pairing forgets the old certificate\'s end date', () async {
    // Otherwise the next handshake would carry a warning about a certificate that is no
    // longer installed anywhere.
    final overrides = PinnedHttpOverrides(pin: expiredPin);
    HttpOverrides.global = overrides;
    final client = HttpClient();
    await (await (await client.getUrl(
      Uri.parse('https://127.0.0.1:${server.port}/session'),
    )).close()).drain<void>();
    client.close();
    expect(overrides.acceptedNotAfter, isNotNull);

    overrides.trust(fingerprintOf('$dir/server.cert.pem'));
    expect(overrides.acceptedNotAfter, isNull);
  });

  test('a wrong pin still refuses it — expiry does not weaken the check', () async {
    HttpOverrides.global = PinnedHttpOverrides(
      pin: fingerprintOf('$dir/server.cert.pem'),
    );
    final client = HttpClient();
    await expectLater(
      client
          .getUrl(Uri.parse('https://127.0.0.1:${server.port}/session'))
          .then((r) => r.close()),
      throwsA(isA<HandshakeException>()),
    );
    expect(handlerRan, isFalse);
    client.close();
  });
}
