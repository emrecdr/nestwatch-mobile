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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

import 'support/certs.dart';

void main() {
  const dir = fixtureDir;
  late HttpServer server;
  late NestwatchClient client;

  /// Every request the server saw, most recent last.
  final seen = <HttpRequest>[];

  /// When true, `/api/screenshot` answers as `AppError::Control` does.
  var captureFails = false;

  /// When true, every path answers 403 — what `require_lan_peer` does to a phone that
  /// has stopped looking like it is on the LAN. It gates the whole server, not one
  /// route, so the stub refuses everything.
  var lanRefused = false;

  /// What the stub reports in `X-Shot-Tier`. `null` stands in for a server predating
  /// the header.
  String? servedTier = 'preview';

  /// What the stub puts in `curfew_note` on an approve.
  ///
  /// The bodies below are **copied off the wire**, not composed here: a dev nestwatch
  /// 0.5.1 was installed on a throwaway port on 2026-09-02, a curfew window covering the
  /// current time was set through `POST /api/curfew`, and a request was submitted and
  /// approved. With bedtime off it answered `{"curfew_note":null,...}`; with bedtime on,
  /// the sentence below. Both are reproduced byte for byte, including the typographic
  /// dash and the escaped quotes, because a stub that answers a tidier shape than the
  /// server tests the parser against a server that does not exist.
  String? curfewNote;

  /// When true, approve answers 400 — what nestwatch does under its mutex for a request
  /// somebody has already resolved.
  var alreadyResolved = false;

  /// Minimal JPEG: SOI, a stub SOF0 declaring 1x1, EOI. Enough for the client to hand
  /// back bytes; this file is about the request, not the image.
  final jpeg = <int>[
    0xFF, 0xD8, //
    0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x01, 0x00, 0x01, //
    0xFF, 0xD9,
  ];

  setUp(() async {
    seen.clear();
    captureFails = false;
    lanRefused = false;
    servedTier = 'preview';
    curfewNote = null;
    alreadyResolved = false;
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
      if (lanRefused) {
        // Before auth, before routing: require_lan_peer is a layer, not a handler.
        response
          ..statusCode = HttpStatus.forbidden
          ..write('{"error":"forbidden"}');
        await response.close();
        return;
      }
      // One entry per path, rather than a chain of eight `else if`s.
      //
      // The chain was not merely long: reading any single case meant simulating every
      // branch above it to know it had not already answered. Two of these still depend on
      // a flag the test sets, and a map makes that visible — `captureFails` and
      // `servedTier` are named where they are used, not carried in from the top.
      //
      // `/p/` stays outside the map on purpose: it is a prefix match, and trap 2 is that
      // nestwatch answers 302 to `/` identically on success and failure, so the stub has
      // to actually redirect or a test asserting "we do not follow it" passes for want of
      // anything to follow.
      final routes = <String, void Function()>{
        '/api/unauthorized': () =>
            response.statusCode = HttpStatus.unauthorized,

        '/api/other-cookie': () => response
          ..statusCode = 200
          ..cookies.add(Cookie('some_other_cookie', 'not-the-session'))
          ..write('{"authenticated":false,"version":"test"}'),

        // What AppError::Control answers: 500, with the OS detail logged on the server
        // and deliberately not in the body.
        '/api/capture-broken': () => response
          ..statusCode = HttpStatus.internalServerError
          ..write('{"error":"operation failed"}'),

        // What a server sends when it ends a session: the same cookie, emptied and
        // expired immediately.
        '/api/logged-out': () => response
          ..statusCode = 200
          ..cookies.add(Cookie('hh_session', '')..maxAge = 0)
          ..write('{"authenticated":false,"version":"test"}'),

        '/api/time-requests': () => response
          ..statusCode = 200
          ..write(
            '[{"id":"r1","ts":"2026-08-26T10:00:00Z","minutes":5,"reason":"x"}]',
          ),

        '/api/screenshot': () {
          if (captureFails) {
            response
              ..statusCode = HttpStatus.internalServerError
              ..write('{"error":"operation failed"}');
            return;
          }
          response
            ..statusCode = 200
            ..headers.contentType = ContentType('image', 'jpeg');
          if (servedTier != null) {
            response.headers.set('x-shot-tier', servedTier!);
          }
          response.add(jpeg);
        },

        '/login': () => response
          ..statusCode = 200
          ..cookies.add(Cookie('hh_session', 'issued-by-test'))
          ..write('{"ok":true}'),

        '/api/time-requests/r1/approve': () {
          if (alreadyResolved) {
            response
              ..statusCode = HttpStatus.badRequest
              ..write('{"error":"no such pending request"}');
            return;
          }
          response
            ..statusCode = 200
            ..write(
              '{"curfew_note":${curfewNote == null ? 'null' : jsonEncode(curfewNote)},'
              '"minutes":30,"ok":true}',
            );
        },

        // A bare `{"ok":true}` — measured, and the reason `Decision.curfewNote` is
        // documented as always null here. Denying grants nothing, so there is nothing
        // for bedtime to swallow.
        '/api/time-requests/r1/deny': () => response
          ..statusCode = 200
          ..write('{"ok":true}'),
      };

      if (request.uri.path.startsWith('/p/')) {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '/');
      } else {
        // Anything unrouted is a signed-in session, which is what most tests want.
        (routes[request.uri.path] ??
            () => response
              ..statusCode = 200
              ..write('{"authenticated":true,"version":"test"}'))();
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
      await client.screenshotPreview(onTimer: true);
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
        await client.screenshotPreview(onTimer: true);
      }
      expect(seen, hasLength(10));
      for (final request in seen) {
        expect(request.uri.queryParameters['tier'], 'preview');
      }
    });

    test('a timer frame carries live=1, so the audit coalesces it', () async {
      // nestwatch audits by ASKER, not by tier. Without `live`, every timer frame
      // writes a `screenshot_taken` row into a log that rotates at 2 MiB with one
      // backup — ~720 rows an hour at this screen's cadence, evicting the record of
      // every login, kill and password change to make room for a timer.
      await client.screenshotPreview(onTimer: true);
      expect(
        seen.single.uri.queryParameters['live'],
        isNotNull,
        reason:
            'the audit keys on presence, and this is what marks a timer frame',
      );
    });

    test(
      'a person-requested frame does NOT, so it is recorded one-for-one',
      () async {
        // The milder error in the other direction, but still an error: a deliberate look
        // at a child's screen that goes unrecorded is exactly the accountability the
        // audit log exists to provide.
        await client.screenshotPreview(onTimer: false);
        expect(seen.single.uri.queryParameters['live'], isNull);
        expect(seen.single.uri.queryParameters['tier'], 'preview');
      },
    );

    test(
      'a full frame served against a preview request is reported, not dropped',
      () async {
        // X-Shot-Tier names what was actually served. A mismatch is worth knowing about —
        // full frames on a 5-second timer produce no error and no failing test, just the
        // cost back — but the frame itself is a real, current picture of the child's
        // screen, and refusing it serves nobody. The caller stops the timer instead.
        servedTier = 'full';
        final frame = await client.screenshotPreview(onTimer: true);
        expect(
          frame.bytes,
          isNotEmpty,
          reason: 'the picture is still delivered',
        );
        expect(frame.isPreview, isFalse);
        expect(frame.servedTier, 'full');
      },
    );

    test(
      'and an older server with no X-Shot-Tier reads as no disagreement',
      () async {
        servedTier = null;
        final frame = await client.screenshotPreview(onTimer: true);
        expect(frame.bytes, isNotEmpty);
        expect(frame.servedTier, isNull);
        expect(
          frame.isPreview,
          isTrue,
          reason:
              'a server that does not say must not be treated as disagreeing',
        );
      },
    );

    test('the client offers no way to ask for another tier', () {
      // A tier parameter with a default is exactly how the wrong one gets sent, so this
      // method has none and there is no full-size equivalent. `onTimer` is required for
      // the same reason and answers a different question — who asked, which is what the
      // audit keys on. Asserting the shape means adding a defaulted parameter has to be
      // a deliberate edit here.
      expect(
        client.screenshotPreview,
        isA<Future<Frame> Function({required bool onTimer})>(),
      );
      expect(
        client.screenshotPreview,
        isNot(isA<Future<Object?> Function()>()),
        reason: 'neither parameter may acquire a default',
      );
    });
  });

  group('what the approve response says, and used to throw away', () {
    // `_resolveTimeRequest` read the status and discarded the body with
    // `final (response, _)`. So `curfew_note` — the sentence nestwatch computes
    // precisely so a parent does not believe a grant took effect when bedtime will
    // swallow it — arrived on every single approve and was never read. Nothing here or
    // in the golden files could have caught that: all nine goldens are GET payloads, so
    // no mutating response body was covered on either side of the contract.

    test('a note on the wire reaches the caller, verbatim', () async {
      const note =
          'Bedtime is in force now, so the PC will still shut down — screen time '
          'and bedtime are separate limits. Use "Later bedtime tonight" on the '
          'Curfew card to move bedtime itself.';
      curfewNote = note;
      final decision = await client.approveTimeRequest('r1');
      expect(decision.acted, isTrue);
      expect(
        decision.curfewNote,
        note,
        reason: 'the phone must not paraphrase a verdict that PC owns',
      );
    });

    test('an ordinary approve carries no note', () async {
      // The control. `curfew_note` is present on every approve and is `null` when there
      // is nothing in the way — so a reader that cannot tell null from a sentence would
      // pass the test above and warn on every grant.
      final decision = await client.approveTimeRequest('r1');
      expect(decision.acted, isTrue);
      expect(decision.curfewNote, isNull);
    });

    test('an already-resolved approve acts on nothing', () async {
      alreadyResolved = true;
      final decision = await client.approveTimeRequest('r1');
      expect(decision.acted, isFalse);

      // Deliberately **not** also asserting the note is null. It would pass, and it
      // would pass for the wrong reason: nestwatch's 400 body is
      // `{"error":"no such pending request"}`, which carries no `curfew_note` at all,
      // so a reader that cheerfully parsed advice off a failed call would satisfy the
      // assertion just as well. Making the stub answer a shape the server never sends
      // would test a server that does not exist — the trap this file's own header
      // warns about — so the guarantee is stated in `Decision`'s doc and left
      // undefended rather than guarded by a check that cannot fail.
    });

    test('deny reports that it acted, and carries no note', () async {
      final decision = await client.denyTimeRequest('r1');
      expect(decision.acted, isTrue);
      expect(decision.curfewNote, isNull);
    });
  });

  group('403 means the same thing on every path', () {
    // A phone on a VPN stops looking like a LAN peer, and `require_lan_peer` refuses the
    // whole server before auth runs. §6 asks for that to be said in those words, because
    // "could not reach that PC" sends a parent to reboot a router over a setting on the
    // phone in their hand.
    //
    // This asserts a shape rather than a status. `screenshotPreview` used to build its
    // own request instead of going through the shared one, and the copy had no 403
    // branch — so the single endpoint a parent reaches for when they are away from the
    // house was the one that could not tell them why it had failed.
    test(
      'including the screenshot, which used to build its own request',
      () async {
        lanRefused = true;

        await expectLater(
          client.session(),
          throwsA(
            isA<NestwatchException>().having(
              (e) => e.failure,
              'failure',
              NestwatchFailure.notOnLan,
            ),
          ),
        );

        await expectLater(
          client.screenshotPreview(onTimer: false),
          throwsA(
            isA<NestwatchException>()
                .having((e) => e.failure, 'failure', NestwatchFailure.notOnLan)
                .having((e) => e.message, 'names the cause', contains('VPN')),
          ),
        );
      },
    );
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

  group('a failed OS operation', () {
    test('a 500 reads as operationFailed, not an unexpected answer', () async {
      await expectLater(
        client.rawGetForTest('/api/capture-broken'),
        throwsA(
          isA<NestwatchException>().having(
            (e) => e.failure,
            'failure',
            NestwatchFailure.operationFailed,
          ),
        ),
      );
    });

    test('and on the screenshot path it says what actually went wrong', () async {
      // AppError::Control answers 500 for every OS operation with a body of
      // "operation failed", so the status says which layer gave up and never why. This
      // is the one call site that knows the operation was a capture — and on the
      // screenshot screen "HTTP 500" is close to useless while the real cause is both
      // common and fixable.
      captureFails = true;
      try {
        await client.screenshotPreview(onTimer: false);
        fail('expected the capture to fail');
      } on NestwatchException catch (e) {
        expect(e.failure, NestwatchFailure.operationFailed);
        expect(e.message, contains('picture of its screen'));
        expect(e.message, contains('1903'));
        expect(
          e.message,
          isNot(contains('500')),
          reason: 'a status code is not an explanation a parent can act on',
        );
      }
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
