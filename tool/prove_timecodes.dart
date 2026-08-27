/// The fourth screen's data path, against a live server.
///
///   dart run tool/prove_timecodes.dart --pin FP --password PW --real 8443
///
/// PLAN.md §7 calls away-from-home support impossible. That holds for *notification* —
/// push needs the server to make outbound connections, which the design forbids — but
/// not for the underlying problem, which nestwatch already solved offline: the parent
/// mints a single-use code, the child types it into the LAN page, and the minutes land
/// in today's budget with no parent action and no internet at redemption.
///
/// Checks the parts the UI cannot be trusted to get right on its own:
///
///   1. a minted code appears in the active list, and is 6 Crockford-base32 characters
///   2. the server's limits are what the app refuses locally against
///   3. minting grants nothing until redeemed — the budget must not move
///   4. the code never appears in the audit log, which is nestwatch's own rule
library;

import 'dart:io';

import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'harness.dart';
import 'dev_server.dart';

Future<void> main(List<String> argv) async {
  final args = parseArgs(argv, known: {'audit', 'password', 'pin', 'real'});
  final port = int.parse(args['real'] ?? '8443');
  await requireListening(port, 'nestwatch');
  HttpOverrides.global = PinnedHttpOverrides(
    pin: Fingerprint.parse(requireArg(args, 'pin')),
  );
  final client = NestwatchClient('127.0.0.1:$port');
  await client.login(requireArg(args, 'password'));

  // ------------------------------------------------- 1. mint and list
  stdout.writeln('1. A minted code shows up as unredeemed');
  final before = await client.timeCodes();
  final minted = await client.issueTimeCode(45);
  check(
    minted.minutes == 45,
    'minted for the minutes asked',
    '${minted.minutes}',
  );

  // 6 characters of Crockford base32 — same generator as pairing tokens, no I/L/O/U.
  //
  // A literal rather than a constant this repo defines: asserting the app's own idea of
  // the length against itself would pin nothing. The number belongs to nestwatch
  // (`CODE_LEN`), so the only useful check is against what a real server actually mints.
  final crockford = RegExp(r'^[0-9A-HJKMNP-TV-Z]{6}$');
  check(
    crockford.hasMatch(minted.code),
    'the code is 6 Crockford-base32 characters',
    '${minted.code.length} chars',
  );

  final after = await client.timeCodes();
  check(after.length == before.length + 1, 'the active list grew by one');
  check(
    after.any((c) => c.code == minted.code),
    'and contains the one just minted',
  );

  // ------------------------------------------- 2. the limits agree
  //
  // Agreement is the claim, and it is the only part of this that needs a live PC. The
  // first version asserted `!isValidMinutes(bad)` on its own line — a pure function,
  // already owned by test/time_code_test.dart, but here reachable only when somebody has
  // a server up and runs this by hand. A property that can be checked on every commit
  // should not be checked once a fortnight.
  stdout.writeln(
    '\n2. The app refuses locally exactly what the server refuses',
  );
  for (final bad in [0, TimeCodeLimits.maxMinutes + 1]) {
    final appRefuses = !TimeCodeLimits.isValidMinutes(bad);
    bool serverRefuses;
    try {
      await client.issueTimeCode(bad);
      serverRefuses = false;
    } on NestwatchException {
      serverRefuses = true;
    }
    check(
      appRefuses && serverRefuses,
      'both refuse $bad minutes',
      'app: ${appRefuses ? 'refused' : 'ALLOWED'}, '
          'server: ${serverRefuses ? 'refused' : 'ALLOWED'}',
    );
  }

  // --------------------------------- 3. minting grants nothing yet
  stdout.writeln('\n3. Minting grants nothing until the child redeems');
  final usageBefore = await client.usageToday();
  await client.issueTimeCode(60);
  final usageAfter = await client.usageToday();
  check(
    usageAfter.extraMinutes == usageBefore.extraMinutes,
    "today's granted minutes did not move",
    '${usageBefore.extraMinutes} -> ${usageAfter.extraMinutes}',
  );

  // ----------------------------------- 4. the code stays out of the log
  stdout.writeln('\n4. The code never reaches the audit log');
  final audit = AuditLog.openOrNull(args);
  if (audit == null) {
    // Through skip(), not a raw writeln. Printing [SKIP] without counting it left
    // finish() free to say "All checks passed" over a check that never ran, which is the
    // thing this whole file exists to be careful about.
    final why =
        'no audit log at ${args['audit'] ?? AuditLog.defaultPath} — pass --audit';
    skip('nestwatch records that a code was issued, never which code', why);
    skip('while still recording that one was issued', why);
  } else {
    check(
      !audit.mentions(minted.code),
      'nestwatch records that a code was issued, never which code',
      'its own rule: "The code itself is a secret (it grants time), so it is NOT '
          'written to the audit log"',
    );
    check(
      audit.mentions('time_code_issued'),
      'while still recording that one was issued',
    );
  }

  client.close();
  finish(
    'All checks passed. Codes mint, list, grant nothing until redeemed, and stay '
    'out of the audit log.',
  );
}
