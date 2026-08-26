/// What `NestwatchClient` actually puts on the wire.
///
/// Same shape as `test/pinning_socket_test.dart`: a real TLS server on loopback, so the
/// assertions are about bytes the server received rather than about arguments a mock was
/// called with.
///
/// This exists chiefly for PLAN.md trap 4. `ShotTier::from_arg` is
/// `Some("preview") => Preview, _ => Full`, so dropping `?tier=preview` produces no
/// error: a valid 200 JPEG comes back at native resolution, and every frame writes a
/// `screenshot_taken` line into the audit log — the record of every login, kill and
/// shutdown, which "a per-frame line evicts ... in about 57 hours of live viewing".
///
/// A mutation audit found that deleting the query parameter left `flutter test` entirely
/// green: the only thing checking it was `tool/prove_screens.dart`, which needs a live
/// nestwatch. For the plan's most dangerous silent failure, that was the wrong place for
/// the only guard.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

import 'pinning_socket_test.dart' show fingerprintOf;

void main() {
  const dir = 'test/fixtures';
  late HttpServer server;
  late NestwatchClient client;

  /// Every request the server saw, most recent last.
  final seen = <HttpRequest>[];

  /// Minimal JPEG: SOI, a stub SOF0 declaring 1x1, EOI. Enough for the client to hand
  /// back bytes; this file is about the request, not the image.
  final jpeg = <int>[
    0xFF, 0xD8, //
    0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x01, 0x00, 0x01, //
    0xFF, 0xD9,
  ];

  setUp(() async {
    seen.clear();
    final context = SecurityContext()
      ..useCertificateChain('$dir/server.cert.pem')
      ..usePrivateKey('$dir/server.key.pem');

    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) async {
      seen.add(request);
      final response = request.response;
      if (request.uri.path.startsWith('/p/')) {
        // Trap 2: nestwatch answers 302 to `/` identically on success and failure.
        // The stub has to actually redirect, or a test asserting "we do not follow it"
        // passes for want of anything to follow.
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '/');
      } else if (request.uri.path == '/api/unauthorized') {
        response.statusCode = HttpStatus.unauthorized;
      } else if (request.uri.path == '/api/other-cookie') {
        response
          ..statusCode = 200
          ..cookies.add(Cookie('some_other_cookie', 'not-the-session'))
          ..write('{"authenticated":false,"version":"test"}');
      } else if (request.uri.path == '/api/logged-out') {
        // What a server sends when it ends a session: the same cookie, emptied and
        // expired immediately.
        response
          ..statusCode = 200
          ..cookies.add(Cookie('hh_session', '')..maxAge = 0)
          ..write('{"authenticated":false,"version":"test"}');
      } else if (request.uri.path == '/api/time-requests') {
        response
          ..statusCode = 200
          ..write(
            '[{"id":"r1","ts":"2026-08-26T10:00:00Z","minutes":5,"reason":"x"}]',
          );
      } else if (request.uri.path == '/api/screenshot') {
        response
          ..statusCode = 200
          ..headers.contentType = ContentType('image', 'jpeg')
          ..add(jpeg);
      } else if (request.uri.path == '/login') {
        response
          ..statusCode = 200
          ..cookies.add(Cookie('hh_session', 'issued-by-test'))
          ..write('{"ok":true}');
      } else {
        response
          ..statusCode = 200
          ..write('{"authenticated":true,"version":"test"}');
      }
      await response.close();
    });

    HttpOverrides.global = PinnedHttpOverrides(
      pin: fingerprintOf('$dir/server.cert.pem'),
    );
    client = NestwatchClient('127.0.0.1:${server.port}');
  });

  tearDown(() async {
    client.close();
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  group('trap 4 — the screenshot tier', () {
    test('?tier=preview is on the wire, every time', () async {
      await client.screenshotPreview();
      expect(seen, hasLength(1));
      expect(
        seen.single.uri.queryParameters['tier'],
        'preview',
        reason:
            'omitting this returns a valid 200 JPEG at the expensive tier and '
            'writes screenshot_taken to the audit log for every frame',
      );
    });

    test('and on the second call, and the tenth', () async {
      for (var i = 0; i < 10; i++) {
        await client.screenshotPreview();
      }
      expect(seen, hasLength(10));
      for (final request in seen) {
        expect(request.uri.queryParameters['tier'], 'preview');
      }
    });

    test('the client offers no way to ask for another tier', () {
      // `screenshotPreview()` takes no arguments on purpose: a tier parameter with a
      // default is exactly how the wrong one gets sent. This asserts the shape rather
      // than the value, so adding such a parameter has to be a deliberate edit here.
      expect(client.screenshotPreview, isA<Future<Object?> Function()>());
    });
  });

  group('requests carry what they should', () {
    test('login posts JSON, which is what the axum handler requires', () async {
      await client.login('hunter2');
      final request = seen.single;
      expect(request.method, 'POST');
      expect(request.uri.path, '/login');
      // `Json(body): Json<LoginRequest>` would answer 415 to a form post.
      expect(request.headers.contentType?.mimeType, 'application/json');
    });

    test('the session cookie is attached to every later request', () async {
      await client.login('hunter2');
      expect(client.cookie, isNotNull);

      await client.session();
      final cookies = seen.last.cookies;
      expect(
        cookies.map((c) => c.name),
        contains(SessionCookie.name),
        reason:
            'dart:io keeps no cookie jar — an unattached cookie means every '
            'request after login is anonymous',
      );
      expect(
        cookies.firstWhere((c) => c.name == SessionCookie.name).value,
        'issued-by-test',
      );
    });

    test('a Set-Cookie on any response is adopted, not just on login', () async {
      // The 30-day sliding expiry re-issues at most every 5 days, and a background poll
      // is as likely to be the request that triggers it as a foreground one.
      expect(client.cookie, isNull);
      await client.login('hunter2');
      expect(client.cookie?.value, 'issued-by-test');
    });

    test('redemption does not follow the redirect', () async {
      // Trap 2: /p/{token} answers 302 identically on success and failure, so following
      // it would fetch the whole dashboard SPA to learn nothing. The stub really does
      // redirect, so a client that followed would land a second request on `/`.
      await client.redeemPairingToken('ABCDEFGHJKMNPQRS');
      expect(seen.single.uri.path, '/p/ABCDEFGHJKMNPQRS');
      expect(
        seen.map((r) => r.uri.path),
        isNot(contains('/')),
        reason: 'a followed 302 would show a second request for the dashboard',
      );
      expect(seen, hasLength(1));
    });

    test('a 401 from /api reads as an expired session, not a puzzle', () async {
      // §5: a 401 means re-prompt for the password, do NOT re-pair — the certificate is
      // still trusted, only the session lapsed. Reporting it as an unexpected answer
      // would send a parent back through pairing for no reason.
      await expectLater(
        client.rawGetForTest('/api/unauthorized'),
        throwsA(
          isA<NestwatchException>().having(
            (e) => e.failure,
            'failure',
            NestwatchFailure.sessionExpired,
          ),
        ),
      );
    });

    test('a cookie that is not hh_session is not mistaken for one', () async {
      await client.rawGetForTest('/api/other-cookie');
      expect(
        client.cookie,
        isNull,
        reason:
            'adopting any Set-Cookie would let an unrelated cookie stand in for '
            'the session, and the real one would never be noticed missing',
      );
    });

    test('a session the server clears is dropped, not kept and retried', () async {
      await client.login('hunter2');
      expect(client.cookie, isNotNull);

      await client.rawGetForTest('/api/logged-out');
      expect(
        client.cookie,
        isNull,
        reason:
            'holding a cookie the server has expired means every later request is '
            'anonymous while the app believes it is signed in — it would retry '
            'forever instead of asking for the password',
      );
    });
  });

  group('connection reuse', () {
    test('ten requests share one connection', () async {
      for (var i = 0; i < 10; i++) {
        await client.session();
      }
      expect(seen, hasLength(10));
      // Same client port for all of them means one TCP connection, so one TLS
      // handshake. Measured against a live server as 10 handshakes -> 1.
      final ports = seen.map((r) => r.connectionInfo?.remotePort).toSet();
      expect(
        ports,
        hasLength(1),
        reason:
            'a client per request means a full TLS handshake every 5 seconds '
            'while live view is open',
      );
    });

    test(
      'close() ends the connection, so a pin change cannot inherit it',
      () async {
        await client.session();
        final before = seen.single.connectionInfo?.remotePort;
        client.close();
        await client.session();
        final after = seen.last.connectionInfo?.remotePort;
        expect(
          after,
          isNot(before),
          reason:
              'a pooled socket predates re-pairing; close() is what stops the next '
              'request riding a connection to a server no longer trusted',
        );
      },
    );
  });
}
