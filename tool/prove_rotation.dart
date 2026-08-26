/// The last two items on PLAN.md §6's verification list.
///
///   dart run tool/prove_rotation.dart --old-pin OLD --new-pin NEW \
///       --real 8445 --lan-gate 9444
///
/// §6: "Re-run `install` and confirm the app refuses the new certificate and prompts to
/// re-pair, rather than silently trusting it", and "Test with a VPN active on the phone:
/// `require_lan_peer` will 403, and the message should say so rather than 'server
/// unreachable'."
///
/// ## A correction to §3 found while setting this up
///
/// §3 says "`generate()` makes a **new key and cert**; `install` rotates both". The first
/// half holds. The second does not: `src/install.rs` computes
///
///     let reuse = !force_new && covered && paths.cert.exists() && paths.key.exists();
///
/// and keeps the existing certificate when it still covers the current addresses —
/// printing "Devices you've already paired won't warn again. Use `--new-cert` to
/// reissue." So the reinstall a parent most often performs produces **no pin mismatch at
/// all**, which is better than the plan implies. Reaching the mismatch on purpose needs
/// `--new-cert`, an address change, or a missing cert.
library;

import 'dart:io';

import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pairing/pair_invite.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pin_mismatch_message.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'harness.dart';
import 'dev_server.dart';


Future<void> main(List<String> argv) async {
  final args = parseArgs(argv, known: {'lan-gate', 'new-pin', 'old-pin', 'real'});
  final port = int.parse(args['real'] ?? '8445');
  final gatePort = int.parse(args['lan-gate'] ?? '9444');

  await requireListening(port, 'the rotated nestwatch');
  await requireListening(gatePort, 'tool/lan_gate_stub.py');
  final oldPin = Fingerprint.parse(requireArg(args, 'old-pin'));
  final newPin = Fingerprint.parse(requireArg(args, 'new-pin'));
  final authority = '127.0.0.1:$port';

  check(
    oldPin != newPin,
    'the harness was given two different fingerprints',
    'if these match, `install` reused the certificate — pass --new-cert',
  );

  final identities = InMemoryServerIdentityStore();
  final sessions = InMemorySessionStore();
  var overrides = PinnedHttpOverrides();
  HttpOverrides.global = overrides;

  PairingController controllerOn(PinnedHttpOverrides o) => PairingController(
    overrides: o,
    identities: identities,
    sessions: sessions,
  );

  // ------------------------------ 1. the old pin is refused, not trusted
  stdout.writeln('\n1. After the certificate changed, the OLD pin is refused');
  final stale = controllerOn(overrides);
  await stale.begin(
    PairInvite.parse('https://$authority/p/AAAAAAAAAAAAAAAA#fp=$oldPin'),
  );
  final s1 = stale.state;
  check(s1 is PairingRefused, 'refused', '${s1.runtimeType}');
  check(
    s1 is! PairingConnected && s1 is! PairingNeedsPassword,
    'and NOT silently trusted — nothing proceeded to a session',
  );

  if (s1 is PairingRefused) {
    check(
      s1.rejection.observed == newPin,
      'the refusal recorded the certificate actually presented',
      '${s1.rejection.observed}',
    );
    check(
      s1.rejection.expected == oldPin,
      'and the one it expected, so a parent can compare both',
    );

    // ------------------ 2. and the explanation names the reinstall first
    stdout.writeln('\n2. The explanation offers the reinstall story first');
    final story = classifyMismatch(s1.rejection);
    check(
      story == MismatchStory.consistentWithReinstall,
      'a freshly minted certificate reads as consistent with a reinstall',
      'certAge=${s1.rejection.certAge.inMinutes} min, story=${story.name}',
    );
    check(
      s1.explanation.contains('nestwatch install'),
      'the copy names the command the parent just ran',
    );
    check(
      s1.explanation.contains('re-scan') || s1.explanation.contains('Re-scan'),
      'and tells them what to do about it',
    );
    check(
      s1.explanation.contains('nestwatch fingerprint'),
      'while still sending them to the PC to check, rather than assuming',
    );
    stdout.writeln('         ---');
    for (final line in s1.explanation.split('\n')) {
      stdout.writeln('         $line');
    }
  }

  // ------------------------------------- 3. re-pairing adopts the new one
  stdout.writeln('\n3. Re-pairing with the new fingerprint works');
  overrides = PinnedHttpOverrides();
  HttpOverrides.global = overrides;
  final repaired = controllerOn(overrides);
  await repaired.begin(
    PairInvite.parse('https://$authority/p/AAAAAAAAAAAAAAAA#fp=$newPin'),
  );
  final s3 = repaired.state;
  check(
    s3 is PairingNeedsPassword || s3 is PairingConnected,
    'pinned to the new certificate',
    '${s3.runtimeType}',
  );
  check(overrides.pin == newPin, 'the live pin is the new fingerprint');
  final stored = await identities.load();
  check(
    stored?.fingerprint == newPin,
    'and the stored identity was replaced, leaving no stale pin behind',
  );

  // ------------------------------------------- 4. the off-LAN 403 message
  //
  // §6 asks for this with a VPN on the phone. Producing a genuinely non-private peer
  // needs a routable address the server can see as such, which a loopback dev box has no
  // way to offer — so a stub answers 403 exactly as `require_lan_peer` does. nestwatch's
  // own tests cover *when* it answers 403; this covers what this app does with one.
  stdout.writeln('\n4. An off-LAN 403 says so, rather than "unreachable"');
  final gate = NestwatchClient('127.0.0.1:$gatePort');
  try {
    await gate.session();
    check(false, 'the gate refused');
  } on NestwatchException catch (e) {
    check(
      e.failure == NestwatchFailure.notOnLan,
      'a 403 reads as notOnLan',
      e.failure.name,
    );
    check(
      e.failure != NestwatchFailure.unreachable,
      'and specifically NOT as unreachable — the distinction §6 asks for',
    );
    final lower = e.message.toLowerCase();
    check(lower.contains('vpn'), 'the message names the likely cause');
    check(
      lower.contains('home network') || lower.contains('same network'),
      'and explains what nestwatch expects',
    );
    check(
      !lower.contains('unreachable') && !lower.contains('could not reach'),
      'without saying "unreachable", which would send the parent to the wrong fix',
    );
    stdout.writeln('         ---\n         ${e.message}');
  }

  finish(
    "All checks passed. A rotated certificate is refused and explained; an "
              "off-LAN 403 is named rather than mistaken for a dead server.",
  );
}
