/// Verified first use, against a nestwatch that actually emits `#fp=`.
///
///   dart run tool/prove_phase1.dart --qr 'the string encoded in the QR' \
///       --fingerprint FP --password PW
///
/// Every earlier check of the verified path used a `#fp=` URL this repo synthesised,
/// because no nestwatch emitted one. PLAN Phase 1 changes that, so this re-asks the same
/// questions against the server's own output — the payload comes from nestwatch's
/// `pair_url`, not from a format this side guessed.
///
/// The distinction being proven is the whole point of Phase 1: whether the fingerprint
/// was known *before* the first handshake (so it never crossed the network) or learned
/// from the server and confirmed by eye.
library;

import 'dart:io';

import 'package:nestwatch_mobile/src/pairing/pair_invite.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'harness.dart';

Future<void> main(List<String> argv) async {
  final args = parseArgs(argv, known: {'fingerprint', 'password', 'qr'});
  final qr = requireArg(args, 'qr');
  final expected = Fingerprint.parse(requireArg(args, 'fingerprint'));
  final password = requireArg(args, 'password');

  // ------------------------------------------- 1. the real payload parses
  stdout.writeln("1. nestwatch's own QR payload");
  final PairInvite invite;
  try {
    invite = PairInvite.parse(qr);
  } on PairInviteFormatException catch (e) {
    stdout.writeln(
      '  [STOP] this app cannot read what nestwatch now emits: $e',
    );
    exit(1);
  }
  check(invite.isVerifiable, 'carries a fingerprint, so it is verifiable');
  check(
    invite.fingerprint == expected,
    'and it is the one `nestwatch fingerprint` prints',
    '${invite.fingerprint}',
  );
  check(
    invite.token != null && invite.token!.length == 16,
    'the token survived the fragment',
    invite.token ?? 'none',
  );
  check(
    invite.redeemUrl.toString() ==
        'https://${invite.authority}/p/${invite.token}',
    'and the redeem URL carries no fragment — the server never sees #fp=',
    invite.redeemUrl.toString(),
  );

  // ------------------------ 2. the pin is set BEFORE the first handshake
  stdout.writeln(
    '\n2. The certificate is checked against a value that never travelled',
  );
  final overrides = PinnedHttpOverrides();
  HttpOverrides.global = overrides;
  final identities = InMemoryServerIdentityStore();
  final controller = PairingController(
    overrides: overrides,
    identities: identities,
    sessions: InMemorySessionStore(),
  
    seen: InMemorySeenRequestStore(),
  );
  check(overrides.pin == null, 'nothing is pinned before pairing starts');

  await controller.begin(invite);
  final state = controller.state;

  check(
    state is! PairingNeedsFingerprintCheck,
    'no trust-on-first-use prompt — this is the difference Phase 1 makes',
    state.runtimeType.toString(),
  );
  check(
    state is PairingConnected || state is PairingNeedsPassword,
    'pinned and past the certificate question',
    state is PairingFailed ? state.message : '',
  );
  check(overrides.pin == expected, 'the live pin came from the QR');

  final stored = await identities.load();
  check(
    stored?.provenance == PinProvenance.verifiedFromQrCode,
    'recorded as VERIFIED, not trusted-on-first-use',
    stored?.provenance.name ?? 'nothing stored',
  );
  check(
    stored?.provenance.isVerified == true,
    'and it may say so, which it could not before Phase 1',
  );

  // ------------------------------------------------ 3. sign in and use it
  stdout.writeln('\n3. The verified pin carries a working session');
  if (state is PairingNeedsPassword) {
    await controller.submitPassword(password);
  }
  final after = controller.state;
  check(after is PairingConnected, 'signed in', after.runtimeType.toString());
  if (after is PairingConnected) {
    check(after.session.authenticated, '/session reports authenticated');
    check(
      after.identity.provenance.isVerified,
      'and the connection is still recorded as verified afterwards',
    );
  }

  finish(
    'All checks passed. Against a Phase 1 nestwatch this app performs verified '
    'first use, with no fingerprint comparison asked of the parent.',
  );
}
