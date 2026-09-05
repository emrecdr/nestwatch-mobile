/// Signing in, and forgetting the PC, take the sign-in notice down.
///
/// ## The loop that could not close
///
/// `SignInNotice` is raised by the background poll when that PC rejects the session, and
/// it was lowered by the background poll and by nothing else. `pollOnce` reaches
/// `lower()` only *after* `client.timeRequests()` has returned — so the one thing that
/// could take the notice down was a request succeeding, and a request cannot succeed
/// while the session is the thing that is broken.
///
/// Two consequences, and the second is the worse one:
///
///   * a parent who opened the app from the launcher and signed in left "Sign in to
///     nestwatch again" sitting on the shade, telling them to do a thing they had just
///     done, until a background round happened to run;
///   * `unpair()` cleared the session, the identity and the announced-request ids, and
///     left the notice standing — pointing at a PC this app had been told to forget.
///
/// ## Why this file drives a real handshake
///
/// `_connect` is private and every route to it makes a request. Testing the *rule* would
/// mean testing that a function calls a function, which is the shape that was already
/// true and already wrong: each unit was correct and nothing joined them up. So this
/// stands up a TLS server on loopback and goes in through `restoreSession`, which is the
/// shortest of the three real paths — one probe, then `_connect`.
///
/// Every test here asserts the connection actually happened as well as what the notice
/// did. Without that control a broken rig would pass the negative case by reaching
/// nothing at all.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/background/sign_in_notice.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

import 'support/tls_server.dart';

void main() {
  late TestTlsServer server;

  /// A signed-in answer from a PC new enough to carry a scope this app can use. Anything
  /// less and `_connect` takes the refusal branch, which deliberately does not withdraw.
  const signedIn =
      '{"authenticated":true,"version":"0.7.0","scope":{"kind":"dashboard"}}';

  setUp(() async {
    server = await TestTlsServer.start(body: signedIn);
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close();
  });

  /// A controller pointed at [server], with a stored identity and cookie so
  /// `restoreSession` has something to check.
  ///
  /// The overrides are installed globally as well as handed to the controller, because
  /// `HttpClient()` consults `HttpOverrides.current` and the controller's own reference
  /// is only used for `trust`/`distrust`.
  PairingController controllerFor(
    SignInNotice notice, {
    required InMemoryServerIdentityStore identities,
    required InMemorySessionStore sessions,
  }) {
    final overrides = PinnedHttpOverrides();
    HttpOverrides.global = overrides;
    return PairingController(
      overrides: overrides,
      identities: identities,
      sessions: sessions,
      forgetAnnounced: InMemorySeenRequestStore().clear,
      withdrawSignInNotice: notice.lower,
    );
  }

  Future<
    ({PairingController controller, List<String> log, SignInNotice notice})
  >
  paired({required bool noticeStanding}) async {
    final identities = InMemoryServerIdentityStore();
    final sessions = InMemorySessionStore();
    await identities.save(
      ServerIdentity(
        host: '127.0.0.1',
        port: server.port,
        fingerprint: server.pin,
        provenance: PinProvenance.verifiedFromQrCode,
        pairedAt: DateTime.utc(2026, 8, 1),
      ),
    );
    await sessions.save(const SessionCookie('a-session'));

    final log = <String>[];
    final notice = SignInNotice.recording(log);
    if (noticeStanding) {
      await notice.raise();
      log.clear();
    }

    final controller = controllerFor(
      notice,
      identities: identities,
      sessions: sessions,
    );
    await controller.restorePin();
    return (controller: controller, log: log, notice: notice);
  }

  test('signing in again takes a standing notice down', () async {
    final t = await paired(noticeStanding: true);
    await t.controller.restoreSession();

    expect(
      t.controller.state,
      isA<PairingConnected>(),
      reason: 'nothing below means anything if the probe never connected',
    );
    expect(t.log, [SignInNotice.lowered]);
  });

  test('and re-arms it, so the next lapse is announced', () async {
    // Withdrawing without clearing would leave the record set, and the next lapse would
    // be swallowed by the very guard that stops the fifteen-minute alarm.
    final t = await paired(noticeStanding: true);
    await t.controller.restoreSession();
    t.log.clear();

    await t.notice.raise();
    expect(t.log, [SignInNotice.raised]);
  });

  test('signing in with no notice standing withdraws nothing', () async {
    // This runs on every ordinary launch, so it must not cancel a notification that was
    // never posted. The connection assertion is the control: without it this passes just
    // as well when the rig never reaches `_connect` at all.
    final t = await paired(noticeStanding: false);
    await t.controller.restoreSession();

    expect(t.controller.state, isA<PairingConnected>());
    expect(t.log, isEmpty);
  });

  test('forgetting the PC takes the notice down too', () async {
    // The fourth thing "Forget this PC" has to delete. It cleared three, and the privacy
    // screen said it cleared all of them — see `store_requirements_test.dart`.
    final t = await paired(noticeStanding: true);
    await t.controller.unpair();

    expect(t.controller.state, isA<PairingIdle>());
    expect(t.log, [SignInNotice.lowered]);
  });

  test('a pairing this app cannot drive leaves the notice standing', () async {
    // An integration pairing authenticates and still cannot read time requests, so the
    // notice — "this phone can no longer tell you when your child asks" — is still true.
    // Withdrawing on every authenticated answer rather than on a usable one would take it
    // down for a phone that is about to go on being useless.
    await server.close();
    server = await TestTlsServer.start(
      body:
          '{"authenticated":true,"version":"0.7.0",'
          '"scope":{"kind":"integration","source":"voortgang"}}',
    );

    final t = await paired(noticeStanding: true);
    await t.controller.restoreSession();

    expect(t.controller.state, isA<PairingFailed>());
    expect(t.log, isEmpty);
  });
}
