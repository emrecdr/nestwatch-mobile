/// Does the pin still hold when the app is iOS?
///
/// PLAN §7 deferred iOS with one honest reservation: "The ATS-vs-`dart:io` inference is
/// sound but still not documented in Apple's or Flutter's words." The inference is that
/// App Transport Security governs `NSURLSession`, while `dart:io`'s `HttpClient` carries
/// its own BoringSSL and never consults it — so a self-signed certificate on a raw LAN
/// address, which ATS would refuse outright, is admitted or refused entirely by
/// `badCertificateCallback`.
///
/// Every source for that is a blog post or a tracker issue. This is the difference between
/// believing it and knowing it: the handshake `test/pinning_socket_test.dart` drives on the
/// host, driven again inside a running iOS app.
///
///   flutter test integration_test/pinning_on_ios_test.dart -d `simulator-or-device`
///
/// ## What this settles, and what it cannot
///
/// It answers the **ATS** question. ATS is a property of the process and applies on the
/// Simulator exactly as on a phone, and `Info.plist` here carries no ATS exception on
/// purpose — if ATS were in the path, these tests fail.
///
/// It says nothing about **local-network privacy**, the separate iOS gate on reaching a
/// LAN address. The Simulator does not implement that at all, which is exactly why PLAN §7
/// says to test on real hardware. Loopback below never leaves the process, so the
/// permission is never consulted. `M15` tracks what is still owed on a device.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

import 'inlined_fixtures.dart';

/// `SecurityContext` takes files, not strings, so the inlined PEMs are written into the
/// app's own temporary directory — inside the sandbox, on whatever device this is.
///
/// `Directory.systemTemp` rather than `path_provider`: dart:io already resolves this to a
/// writable sandbox path on both platforms, and adding a package to the shipped app for
/// something only a test needs is a poor trade — especially in a repo whose one dependency
/// rule is audited on every `pub add`.
Future<String> _write(String name, String contents) async {
  final file = File('${Directory.systemTemp.path}/$name');
  await file.writeAsString(contents);
  return file.path;
}

Fingerprint _fingerprintOf(String pem) => Fingerprint.ofDer(
  base64.decode(
    pem
        .split('\n')
        .where((l) => !l.startsWith('-----'))
        .join()
        .replaceAll(RegExp(r'\s'), ''),
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late Fingerprint servedPin;
  late Fingerprint otherPin;
  var handlerRan = false;

  setUp(() async {
    handlerRan = false;
    final certPath = await _write('server.cert.pem', serverCertPem);
    final keyPath = await _write('server.key.pem', serverKeyPem);

    final context = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);

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

    servedPin = _fingerprintOf(serverCertPem);
    otherPin = _fingerprintOf(impostorCertPem);
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  test('this is actually running on the platform under question', () {
    // Without this the whole file could pass on the host and prove nothing about iOS.
    expect(
      Platform.operatingSystem,
      anyOf('ios', 'android'),
      reason: 'run with -d against a device; on the host this file is meaningless',
    );
  });

  test('the two fixtures are different certificates', () {
    expect(servedPin, isNot(otherPin));
  });

  test('a matching pin completes the request — ATS is not in the path', () async {
    HttpOverrides.global = PinnedHttpOverrides(pin: servedPin);
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('https://127.0.0.1:${server.port}/session'),
    );
    final body = await (await request.close())
        .transform(utf8.decoder)
        .join();
    client.close();

    expect(body, contains('"version":"test"'));
    expect(
      handlerRan,
      isTrue,
      reason:
          'a self-signed certificate on a bare IP, admitted by badCertificateCallback. '
          'If ATS governed dart:io, this connection could not exist.',
    );
  });

  test('a wrong pin is refused, and nothing reaches the server', () async {
    HttpOverrides.global = PinnedHttpOverrides(pin: otherPin);
    final client = HttpClient();
    await expectLater(
      client
          .getUrl(Uri.parse('https://127.0.0.1:${server.port}/session'))
          .then((r) => r.close()),
      throwsA(isA<HandshakeException>()),
    );
    expect(
      handlerRan,
      isFalse,
      reason: 'refusal has to precede the request, on this platform too',
    );
    client.close();
  });

  test('no pin at all refuses everything', () async {
    HttpOverrides.global = PinnedHttpOverrides();
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
