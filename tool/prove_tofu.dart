/// Walking-skeleton step 3 (docs/PLAN.md §9), proven against live servers.
///
///   dart run tool/prove_tofu.dart --real 8443 --impostor 8444 --pin `nestwatch fingerprint`
///
/// The question step 3 has to answer is not "does a QR parse" but "does the app end up
/// pinned to the right certificate, by both routes, and does it refuse the wrong one".
/// Six checks:
///
///   1. today's QR (no `#fp=`) parses, and reports itself as unverifiable
///   2. trust-on-first-use observes the certificate WITHOUT trusting it, and what it
///      observes equals `nestwatch fingerprint`
///   3. confirming that observation pins it and the session probe succeeds
///   4. a Phase-1 QR (`#fp=` present) pins before the first connection — no prompt
///   5. a Phase-1 QR naming the WRONG certificate is refused, never downgraded to a
///      trust-on-first-use prompt
///   6. the provenance recorded distinguishes 3 from 4, and survives a store round trip
///
/// Check 5 is the one that matters most: the failure it guards against is a client that,
/// on mismatch, quietly falls back to asking the user — which would make Phase 1's
/// fingerprint decorative.
library;

import 'dart:io';

import 'package:nestwatch_mobile/src/pairing/pair_invite.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

int _failures = 0;

void _check(bool ok, String label, [String detail = '']) {
  stdout.writeln(
    '  [${ok ? 'PASS' : 'FAIL'}] $label'
    '${detail.isEmpty ? '' : '\n         $detail'}',
  );
  if (!ok) _failures++;
}

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i < argv.length - 1; i += 2) {
    args[argv[i].replaceFirst('--', '')] = argv[i + 1];
  }
  final realPort = int.parse(args['real'] ?? '8443');
  final impostorPort = int.parse(args['impostor'] ?? '8444');
  final realPin = Fingerprint.parse(args['pin']!);

  final overrides = PinnedHttpOverrides();
  HttpOverrides.global = overrides;

  PairingController fresh() => PairingController(
    overrides: overrides,
    store: InMemoryServerIdentityStore(),
  );

  // ---------------------------------------------- 1. today's QR, no fragment
  stdout.writeln("1. Today's pairing QR (no #fp= — Phase 1 has not landed)");
  final todayPayload = 'https://127.0.0.1:$realPort/p/EG629F4DQDDHS44V';
  final today = PairInvite.parse(todayPayload);
  _check(today.fingerprint == null, 'parses with no fingerprint');
  _check(!today.isVerifiable, 'reports itself as not verifiable');
  _check(
    today.token == 'EG629F4DQDDHS44V' && today.port == realPort,
    'token and port recovered',
    '${today.token} @ ${today.authority}',
  );

  // ------------------------------------------- 2. observe without trusting
  stdout.writeln('\n2. Trust-on-first-use observes without trusting');
  overrides.distrust();
  final c2 = fresh();
  await c2.begin(today);
  final st = c2.state;
  _check(
    st is PairingNeedsFingerprintCheck,
    'stopped to ask, rather than connecting',
    st.runtimeType.toString(),
  );
  if (st is PairingNeedsFingerprintCheck) {
    _check(
      st.observed == realPin,
      'what it observed equals `nestwatch fingerprint`',
      '${st.observed}',
    );
    _check(
      overrides.pin == null,
      'and nothing is pinned yet — the observation trusted nothing',
    );
  }

  // ------------------------------------------------ 3. confirming pins it
  stdout.writeln(
    '\n3. Confirming the fingerprint pins it and the probe succeeds',
  );
  await c2.confirmFirstUse();
  final st3 = c2.state;
  _check(
    st3 is PairingSucceeded,
    'paired',
    st3 is PairingFailed ? st3.message : '',
  );
  if (st3 is PairingSucceeded) {
    _check(
      st3.identity.provenance == PinProvenance.trustedOnFirstUse,
      'provenance recorded as trust-on-first-use',
    );
    _check(
      !st3.identity.provenance.isVerified,
      'and it does NOT claim to be verified',
    );
    _check(
      st3.session.version.isNotEmpty,
      'session probe returned a version',
      st3.session.toString(),
    );
  }

  // ------------------------------- 4. Phase-1 QR pins before first connection
  stdout.writeln('\n4. A Phase-1 QR (#fp= present) pins before connecting');
  overrides.distrust();
  final phase1 = PairInvite.parse('$todayPayload#fp=$realPin');
  _check(phase1.isVerifiable, 'parses as verifiable');
  final c4 = fresh();
  await c4.begin(phase1);
  final st4 = c4.state;
  _check(
    st4 is PairingSucceeded,
    'paired with no fingerprint prompt',
    st4.runtimeType.toString(),
  );
  if (st4 is PairingSucceeded) {
    _check(
      st4.identity.provenance == PinProvenance.verifiedFromQrCode,
      'provenance recorded as verified from the QR code',
    );
  }

  // --------------------------- 5. wrong fingerprint is refused, not downgraded
  stdout.writeln('\n5. A Phase-1 QR naming the WRONG certificate is refused');
  overrides.distrust();
  // The real server's fingerprint, pointed at the impostor's port: the QR names a
  // certificate that host will not present.
  final wrong = PairInvite.parse(
    'https://127.0.0.1:$impostorPort/p/EG629F4DQDDHS44V#fp=$realPin',
  );
  final c5 = fresh();
  await c5.begin(wrong);
  final st5 = c5.state;
  _check(st5 is PairingRefused, 'refused', st5.runtimeType.toString());
  _check(
    st5 is! PairingNeedsFingerprintCheck,
    'and NOT downgraded to a trust-on-first-use prompt',
  );
  if (st5 is PairingRefused) {
    _check(
      st5.rejection.observed != realPin,
      'the refusal recorded the certificate actually presented',
      '${st5.rejection.observed}',
    );
    _check(
      st5.explanation.contains('nestwatch fingerprint'),
      'the explanation points the parent at the PC itself',
    );
    stdout.writeln('         ---');
    for (final line in st5.explanation.split('\n')) {
      stdout.writeln('         $line');
    }
  }

  // ------------------------------------------ 6. provenance survives storage
  stdout.writeln('\n6. Provenance survives a store round trip');
  final store = InMemoryServerIdentityStore();
  for (final p in PinProvenance.values) {
    await store.save(
      ServerIdentity(
        host: '127.0.0.1',
        port: realPort,
        fingerprint: realPin,
        provenance: p,
        pairedAt: DateTime.utc(2026, 8, 26),
      ),
    );
    final back = await store.load();
    _check(
      back?.provenance == p && back?.fingerprint == realPin,
      'round-trips ${p.name}',
    );
  }

  stdout.writeln('\n${'-' * 70}');
  stdout.writeln(
    _failures == 0
        ? 'All checks passed. Both pairing routes end pinned to the right certificate, '
              'and the wrong one is refused rather than downgraded.'
        : '$_failures check(s) FAILED.',
  );
  exit(_failures == 0 ? 0 : 1);
}
