/// Walking-skeleton step 4 (docs/PLAN.md §9), proven against a live server.
///
///   dart run tool/prove_login.dart --pin FP --password PW --real 8443 [--token TOK]
///
/// `--token` is optional, and the reason is worth stating: a pairing token is single-use
/// with a 15-minute TTL, so a harness that required one would fail its own second run
/// and report that as a product defect. Without it, the token checks are SKIPPED aloud
/// and everything else still runs. To exercise them, mint one first:
///
///   cd ../nestwatch && NESTWATCH_DATA_DIR=/tmp/nestwatch-dev cargo run -- pair
///
/// Checks:
///
///   1. a real token redeems, and `/session` — not the redirect — is what says so
///   2. the SAME token again is refused silently, and lands on the password prompt
///      rather than an error, because that is trap 3's expected path
///   3. the control password signs in
///   4. the session survives a process restart with no password re-entry
///   5. signing out drops the session but keeps the pin; unpairing drops both
///   6. the cookie never appears in a string representation
///   7. a wrong password is reported as wrong, and does NOT drop the pin
///
/// Check 4 is the deliverable. Check 2 is the one that would silently rot: if the app
/// ever started treating a spent token as a failure, pairing would break for every
/// parent who did what the QR told them to.
///
/// Check 7 runs LAST on purpose. `LoginLimiter::default` (nestwatch `src/auth.rs`) locks
/// an IP out for 60 seconds after 5 failures, so a deliberate wrong password spends
/// budget that everything after it would need. It used to run fourth, and a re-run
/// inside the lockout window reported six unrelated failures.
library;

import 'dart:io';

import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/pairing/pair_invite.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'harness.dart';
import 'dev_server.dart';

/// Coverage this run did not achieve, said out loud.
///
/// A harness that quietly drops a check reads afterwards as though it covered
/// everything. Skips are counted and reprinted in the summary.
Future<void> main(List<String> argv) async {
  final args = parseArgs(argv, known: {'password', 'pin', 'real', 'token'});
  final port = int.parse(args['real'] ?? '8443');
  await requireListening(port, 'nestwatch');
  final pin = Fingerprint.parse(requireArg(args, 'pin'));
  final password = requireArg(args, 'password');
  final token = args['token'];
  final authority = '127.0.0.1:$port';

  // Storage outlives the "process restarts" below, exactly as secure storage does.
  final identities = InMemoryServerIdentityStore();
  final sessions = InMemorySessionStore();

  var overrides = PinnedHttpOverrides()..trust(pin);
  HttpOverrides.global = overrides;

  PairingController controllerOn(PinnedHttpOverrides o) => PairingController(
    overrides: o,
    identities: identities,
    sessions: sessions,

    forgetAnnounced: InMemorySeenRequestStore().clear,
  );

  // ------------------------------------------------------------- preflight
  //
  // A tripped rate limiter makes every sign-in below fail for a reason that has
  // nothing to do with the code. Distinguish that here rather than reporting six
  // confusing failures.
  stdout.writeln('0. Preflight');
  try {
    final info = await NestwatchClient(authority).session();
    check(true, 'server reachable and pinned', 'nestwatch ${info.version}');
  } on NestwatchException catch (e) {
    stdout.writeln('  [STOP] ${e.message}');
    exit(2);
  }
  // Sign in once, correctly, before anything else. Two reasons, and the second is not
  // obvious: `limiter.record_success` CLEARS the lockout (nestwatch `src/auth.rs`), so a
  // successful preflight resets whatever budget a previous run spent. An earlier version
  // probed with a deliberately wrong password and steadily starved its own re-runs.
  try {
    await NestwatchClient(authority).login(password);
    check(true, 'the control password is accepted, and the limiter is clear');
  } on NestwatchException catch (e) {
    switch (e.failure) {
      case NestwatchFailure.rateLimited:
        stdout.writeln(
          '  [STOP] That PC is rate-limited right now (5 failures in 60s locks an IP '
          'out).\n         This is the harness environment, not a defect. Wait a '
          'minute and re-run.',
        );
        exit(2);
      case NestwatchFailure.badPassword:
        stdout.writeln(
          '  [STOP] --password is not the control password for that PC.\n'
          '         Nothing below would mean anything, so this stops here.',
        );
        exit(2);
      default:
        stdout.writeln('  [STOP] ${e.message}');
        exit(2);
    }
  }

  // ------------------------------------------------- 1-2. token redemption
  stdout.writeln('\n1. A real pairing token redeems');
  var controller = controllerOn(overrides);
  if (token == null) {
    skip(
      'token redemption',
      'no --token given. A token is single-use with a 15-minute TTL, so this is '
          'opt-in; mint one with `nestwatch pair` to cover it.',
    );
    skip('the same token again is spent', 'depends on the check above');
  } else {
    await controller.begin(
      PairInvite.parse('https://$authority/p/$token#fp=$pin'),
    );
    final s1 = controller.state;
    if (s1 is PairingNeedsPassword &&
        s1.reason == PasswordPrompt.tokenSpentOrExpired) {
      skip(
        'token redemption',
        'that token was already spent or has expired — mint a fresh one with '
            '`nestwatch pair`. (Not a product failure: this is exactly the '
            'fallback check 2 asserts.)',
      );
      skip('the same token again is spent', 'depends on the check above');
    } else {
      check(s1 is PairingConnected, 'connected and signed in', '$s1');
      if (s1 is PairingConnected) {
        check(s1.session.authenticated, '/session reports authenticated');
        check(
          s1.identity.provenance == PinProvenance.verifiedFromQrCode,
          'pinned from the QR fingerprint',
        );
      }
      check(await sessions.load() != null, 'the cookie was persisted');

      stdout.writeln('\n2. The SAME token again — spent, and not an error');
      await sessions.clear();
      final o2 = PinnedHttpOverrides()..trust(pin);
      HttpOverrides.global = o2;
      final c2 = controllerOn(o2);
      await c2.begin(PairInvite.parse('https://$authority/p/$token#fp=$pin'));
      final s2 = c2.state;
      check(
        s2 is PairingNeedsPassword,
        'fell back to the password prompt',
        '$s2',
      );
      if (s2 is PairingNeedsPassword) {
        check(
          s2.reason == PasswordPrompt.tokenSpentOrExpired,
          'and says why: ${s2.reason.name}',
        );
      }
      check(c2.current != null, 'the PC is still pinned even so');
      overrides = o2;
      controller = c2;
    }
  }

  // ------------------------------------------------------ 3. password login
  stdout.writeln('\n3. The control password signs in');
  if (controller.current == null) {
    // No token path ran, so pair by address first — the state a typed address leaves.
    // A manual invite carries no fingerprint, so this takes the trust-on-first-use
    // route and stops to ask, exactly as it would for a parent.
    await controller.begin(PairInvite.manual(host: '127.0.0.1', port: port));
    if (controller.state is PairingNeedsFingerprintCheck) {
      await controller.confirmFirstUse();
    }
  }
  await sessions.clear();
  final beforeLogin = controller.state;
  check(
    beforeLogin is PairingNeedsPassword,
    'sitting at the password prompt',
    '${beforeLogin.runtimeType}',
  );
  await controller.submitPassword(password);
  final s3 = controller.state;
  check(s3 is PairingConnected, 'connected', '$s3');
  if (s3 is PairingConnected) {
    check(s3.session.authenticated, '/session reports authenticated');
  }
  check(await sessions.load() != null, 'the cookie was persisted');

  // --------------------------------------- 4. survives a process restart
  stdout.writeln('\n4. The session survives a restart, with no password');
  final restarted = PinnedHttpOverrides();
  HttpOverrides.global = restarted;
  check(restarted.pin == null, 'the fresh process starts with no pin');
  final c4 = controllerOn(restarted);

  // The two halves, in the order main() runs them. restorePin is what the app awaits
  // before its first frame; restoreSession is what it starts behind that frame.
  await c4.restorePin();
  check(
    restarted.pin == pin,
    'the pin is back before the first frame, and before any request',
    'this is the half that must stay awaited',
  );
  check(
    c4.state is PairingBusy,
    'and the parent is told a PC is being reached, not shown a blank screen',
    '${c4.state}',
  );

  await c4.restoreSession();
  final s4 = c4.state;
  check(
    s4 is PairingConnected,
    'restored straight to a signed-in session',
    s4 is PairingNeedsPassword ? 'asked for a password: ${s4.message}' : '$s4',
  );

  // ------------------------------- 5. sign out vs unpair are different
  stdout.writeln('\n5. Signing out is not un-pairing');
  await c4.signOut();
  check(
    c4.state is PairingNeedsPassword,
    'sign out asks for the password again',
  );
  check(await identities.load() != null, 'the pinned PC is still on record');
  check(await sessions.load() == null, 'but the session is gone');
  check(restarted.pin == pin, 'and the pin is still applied');

  // ------------------------------------- 6. the cookie is never printed
  stdout.writeln('\n6. The session token never leaks into a string');
  const secret = 'super-secret-session-value';
  const cookie = SessionCookie(secret);
  check(
    !cookie.toString().contains(secret),
    'SessionCookie.toString() redacts it',
  );
  check(
    !NestwatchClient(
      authority,
      cookie: cookie,
    ).cookie.toString().contains(secret),
    'and so does the client it is held in',
  );

  // ------------------------------------------------- 7. a wrong password
  //
  // LAST: this spends one of the five attempts before a 60-second lockout, so
  // anything after it would be running on borrowed budget.
  stdout.writeln('\n7. A wrong password is reported, and keeps the pin');
  final pinBefore = restarted.pin;
  await c4.submitPassword('definitely-not-the-password');
  final s7 = c4.state;
  check(s7 is PairingNeedsPassword, 'stayed on the password prompt');
  if (s7 is PairingNeedsPassword) {
    check(
      s7.reason == PasswordPrompt.wrongPassword,
      'reported as a wrong password, not a network error',
      s7.reason.name,
    );
  }
  check(
    restarted.pin == pinBefore && restarted.pin != null,
    'the certificate pin is untouched by a failed sign-in',
  );

  // Unpair last of all, so the checks above ran against a real pairing.
  await c4.unpair();
  check(c4.state is PairingIdle, 'unpair returns to the start');
  check(await identities.load() == null, 'the pinned PC is forgotten');
  check(restarted.pin == null, 'and the pin is dropped');

  finish(
    'All run checks passed. A spent token degrades to the password prompt, and '
    'the session survives a restart without one.',
  );
}
