/// A real TLS server on loopback, for the tests that need a handshake rather than a stub.
///
/// Five files were building this: `SecurityContext`, `useCertificateChain`,
/// `usePrivateKey`, `bindSecure` on port 0, and a handler. Four of them are host tests and
/// can share; the fifth is `integration_test/pinning_on_ios_test.dart`, which runs inside
/// the app sandbox where `test/fixtures/` does not exist and reads its certificates from
/// `inlined_fixtures.dart` instead. That one stays separate, and the reason is worth
/// knowing before somebody tries to unify it.
///
/// The property these tests actually assert is usually **whether the handler ran at all** —
/// a refused handshake means no request reached the server, which is the pin working. So
/// that flag is part of the rig rather than something each file re-invents.
library;

import 'dart:io';

import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';

import 'certs.dart';

/// A running server, its pin, and whether anything ever reached it.
class TestTlsServer {
  final HttpServer _server;

  /// The fingerprint of the certificate this server presents.
  final Fingerprint pin;

  /// Set by the request handler. Stays false when the handshake is refused, which is the
  /// assertion that matters in most of these tests.
  bool handlerRan = false;

  TestTlsServer._(this._server, this.pin);

  int get port => _server.port;
  Uri url(String path) => Uri.parse('https://127.0.0.1:$port$path');

  /// Serve [fixture] (`server`, `impostor`, `expired`) and answer every request with
  /// [body]. The handler is deliberately trivial: these tests are about the handshake,
  /// and a file that needs routing should keep its own.
  static Future<TestTlsServer> start({
    String fixture = 'server',
    String body = '{"authenticated":false,"version":"test"}',
    int status = 200,
  }) async {
    final context = SecurityContext()
      ..useCertificateChain('$fixtureDir/$fixture.cert.pem')
      ..usePrivateKey('$fixtureDir/$fixture.key.pem');

    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0, // any free port
      context,
    );
    final running = TestTlsServer._(
      server,
      fingerprintOf('$fixtureDir/$fixture.cert.pem'),
    );
    server.listen((request) async {
      running.handlerRan = true;
      request.response
        ..statusCode = status
        ..write(body);
      await request.response.close();
    });
    return running;
  }

  Future<void> close() => _server.close(force: true);
}
