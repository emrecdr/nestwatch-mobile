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
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

int _failures = 0;
int _skipped = 0;

void _check(bool ok, String label, [String detail = '']) {
  stdout.writeln(
    '  [${ok ? 'PASS' : 'FAIL'}] $label'
    '${detail.isEmpty ? '' : '\n         $detail'}',
  );
  if (!ok) _failures++;
}

/// Coverage this run did not achieve, said out loud.
///
/// A harness that quietly drops a check reads afterwards as though it covered
/// everything. Skips are counted and reprinted in the summary.
void _skip(String label, String why) {
  stdout.writeln('  [SKIP] $label\n         $why');
  _skipped++;
}

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i < argv.length - 1; i += 2) {
    args[argv[i].replaceFirst('--', '')] = argv[i + 1];
  }
  final port = int.parse(args['real'] ?? '8443');
  final pin = Fingerprint.parse(args['pin']!);
  final password = args['password']!;
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
  );

  // ------------------------------------------------------------- preflight
  //
  // A tripped rate limiter makes every sign-in below fail for a reason that has
  // nothing to do with the code. Distinguish that here rather than reporting six
  // confusing failures.
  stdout.writeln('0. Preflight');
  try {
    final info = await NestwatchClient(authority).session();
    _check(true, 'server reachable and pinned', 'nestwatch ${info.version}');
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
    _check(true, 'the control password is accepted, and the limiter is clear');
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
    _skip(
      'token redemption',
      'no --token given. A token is single-use with a 15-minute TTL, so this is '
          'opt-in; mint one with `nestwatch pair` to cover it.',
    );
    _skip('the same token again is spent', 'depends on the check above');
  } else {
    await controller.begin(
      PairInvite.parse('https://$authority/p/$token#fp=$pin'),
    );
    final s1 = controller.state;
    if (s1 is PairingNeedsPassword &&
        s1.reason == PasswordPrompt.tokenSpentOrExpired) {
      _skip(
        'token redemption',
        'that token was already spent or has expired — mint a fresh one with '
            '`nestwatch pair`. (Not a product failure: this is exactly the '
            'fallback check 2 asserts.)',
      );
      _skip('the same token again is spent', 'depends on the check above');
    } else {
      _check(s1 is PairingConnected, 'connected and signed in', '$s1');
      if (s1 is PairingConnected) {
        _check(s1.session.authenticated, '/session reports authenticated');
        _check(
          s1.identity.provenance == PinProvenance.verifiedFromQrCode,
          'pinned from the QR fingerprint',
        );
      }
      _check(await sessions.load() != null, 'the cookie was persisted');

      stdout.writeln('\n2. The SAME token again — spent, and not an error');
      await sessions.clear();
      final o2 = PinnedHttpOverrides()..trust(pin);
      HttpOverrides.global = o2;
      final c2 = controllerOn(o2);
      await c2.begin(PairInvite.parse('https://$authority/p/$token#fp=$pin'));
      final s2 = c2.state;
      _check(
        s2 is PairingNeedsPassword,
        'fell back to the password prompt',
        '$s2',
      );
      if (s2 is PairingNeedsPassword) {
        _check(
          s2.reason == PasswordPrompt.tokenSpentOrExpired,
          'and says why: ${s2.reason.name}',
        );
      }
      _check(c2.current != null, 'the PC is still pinned even so');
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
  _check(
    beforeLogin is PairingNeedsPassword,
    'sitting at the password prompt',
    '${beforeLogin.runtimeType}',
  );
  await controller.submitPassword(password);
  final s3 = controller.state;
  _check(s3 is PairingConnected, 'connected', '$s3');
  if (s3 is PairingConnected) {
    _check(s3.session.authenticated, '/session reports authenticated');
  }
  _check(await sessions.load() != null, 'the cookie was persisted');

  // --------------------------------------- 4. survives a process restart
  stdout.writeln('\n4. The session survives a restart, with no password');
  final restarted = PinnedHttpOverrides();
  HttpOverrides.global = restarted;
  _check(restarted.pin == null, 'the fresh process starts with no pin');
  final c4 = controllerOn(restarted);
  await c4.restore();
  final s4 = c4.state;
  _check(
    s4 is PairingConnected,
    'restored straight to a signed-in session',
    s4 is PairingNeedsPassword ? 'asked for a password: ${s4.message}' : '$s4',
  );
  _check(restarted.pin == pin, 'and re-applied the pin before any request');

  // ------------------------------- 5. sign out vs unpair are different
  stdout.writeln('\n5. Signing out is not un-pairing');
  await c4.signOut();
  _check(
    c4.state is PairingNeedsPassword,
    'sign out asks for the password again',
  );
  _check(await identities.load() != null, 'the pinned PC is still on record');
  _check(await sessions.load() == null, 'but the session is gone');
  _check(restarted.pin == pin, 'and the pin is still applied');

  // ------------------------------------- 6. the cookie is never printed
  stdout.writeln('\n6. The session token never leaks into a string');
  const secret = 'super-secret-session-value';
  const cookie = SessionCookie(secret);
  _check(
    !cookie.toString().contains(secret),
    'SessionCookie.toString() redacts it',
  );
  _check(
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
  _check(s7 is PairingNeedsPassword, 'stayed on the password prompt');
  if (s7 is PairingNeedsPassword) {
    _check(
      s7.reason == PasswordPrompt.wrongPassword,
      'reported as a wrong password, not a network error',
      s7.reason.name,
    );
  }
  _check(
    restarted.pin == pinBefore && restarted.pin != null,
    'the certificate pin is untouched by a failed sign-in',
  );

  // Unpair last of all, so the checks above ran against a real pairing.
  await c4.unpair();
  _check(c4.state is PairingIdle, 'unpair returns to the start');
  _check(await identities.load() == null, 'the pinned PC is forgotten');
  _check(restarted.pin == null, 'and the pin is dropped');

  stdout.writeln('\n${'-' * 70}');
  if (_skipped > 0) {
    stdout.writeln(
      '$_skipped check(s) SKIPPED — see above; coverage is incomplete.',
    );
  }
  stdout.writeln(
    _failures == 0
        ? 'All run checks passed. A spent token degrades to the password prompt, and '
              'the session survives a restart without one.'
        : '$_failures check(s) FAILED.',
  );
  exit(_failures == 0 ? 0 : 1);
}
