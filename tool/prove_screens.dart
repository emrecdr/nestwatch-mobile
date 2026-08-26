/// Walking-skeleton step 5 (docs/PLAN.md §9), proven against a live server.
///
///   dart run tool/prove_screens.dart --pin FP --password PW --real 8443
///
/// Checks the three screens' data paths, not their pixels:
///
///   1. `/api/time-requests` parses, and the queue is capped at 5 server-side
///   2. approve grants once; a second approve reports "already resolved" rather than
///      throwing, because the server answers 400 and that is an ordinary race
///   3. deny resolves without granting minutes
///   4. `/api/usage/today` parses, including `remaining_mins: null` under an unlimited
///      budget and the two fields that separate "quiet day" from "dead enforcer"
///   5. the screenshot is fetched as `?tier=preview` — verified by SIZE, since the
///      wrong tier returns a valid JPEG too and would otherwise pass silently
///   6. every `/api/*` path answers 401 once signed out, and that reads as
///      `sessionExpired` rather than a generic failure
///
/// Check 5 is the one worth having. Trap 4 has no error path: omitting the parameter
/// returns a perfectly good image at the expensive tier, and pollutes the audit log
/// while doing it. Only the dimensions tell you which tier you got.
library;

import 'dart:io';

import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'harness.dart';
import 'dev_server.dart';


/// Width and height out of a JPEG's SOF marker.
///
/// Reading the dimensions is the only way to tell the tiers apart on the wire: both are
/// valid JPEGs and both return 200. `PREVIEW_W = 960` in nestwatch `src/control/mod.rs`.
({int width, int height})? jpegSize(List<int> bytes) {
  var i = 2; // skip SOI
  while (i + 9 < bytes.length) {
    if (bytes[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = bytes[i + 1];
    // SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15 carry the frame header.
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      return (width: width, height: height);
    }
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    i += 2 + length;
  }
  return null;
}

/// Submit a request the way the child's page does — unauthenticated, LAN-gated.
Future<void> main(List<String> argv) async {
  final args = parseArgs(argv, known: {'audit', 'password', 'pin', 'real'});
  final port = int.parse(args['real'] ?? '8443');
  final authority = '127.0.0.1:$port';
  final password = requireArg(args, 'password');

  HttpOverrides.global = PinnedHttpOverrides()
    ..trust(Fingerprint.parse(requireArg(args, 'pin')));

  stdout.writeln('0. Sign in');
  final client = await signInOrStop(authority, password);
  check(client.hasSession, 'signed in, cookie held');

  // ------------------------------------------------------ 1. time requests
  stdout.writeln('\n1. Time requests');
  await submitAsChild(authority, 15, 'one more level');
  await submitAsChild(authority, 30, 'homework video');
  final pending = await client.timeRequests();
  check(
    pending.length >= 2,
    'the queue lists what the child submitted',
    '${pending.length} pending',
  );
  check(pending.length <= 5, 'and never exceeds the server-side cap of 5');
  final first = pending.first;
  check(
    first.id.isNotEmpty && first.minutes > 0,
    'a request parses',
    '${first.minutes} min — "${first.reason}"',
  );
  check(first.submittedAt != null, 'and its timestamp parses');

  // -------------------------------------------- 2. approve, then approve again
  stdout.writeln('\n2. Approve grants once');
  final before = await client.usageToday();
  final granted = await client.approveTimeRequest(first.id);
  check(granted, 'the first approve reports that it acted');
  final again = await client.approveTimeRequest(first.id);
  check(!again, 'the second reports "already resolved" instead of throwing');
  final after = await client.usageToday();
  check(
    after.extraMinutes == before.extraMinutes + first.minutes,
    'the minutes were granted exactly once',
    '${before.extraMinutes} -> ${after.extraMinutes} '
        '(+${first.minutes} requested)',
  );

  // ---------------------------------------------------------------- 3. deny
  stdout.writeln('\n3. Deny resolves without granting');
  final remaining = await client.timeRequests();
  if (remaining.isEmpty) {
    check(false, 'there was a second request to deny');
  } else {
    final target = remaining.first;
    final denied = await client.denyTimeRequest(target.id);
    check(denied, 'deny reports that it acted');
    check(
      !await client.denyTimeRequest(target.id),
      'and a second deny reports "already resolved"',
    );
    final afterDeny = await client.usageToday();
    check(
      afterDeny.extraMinutes == after.extraMinutes,
      'no minutes were granted by denying',
    );
    check(
      !(await client.timeRequests()).any((r) => r.id == target.id),
      'and it left the queue',
    );
  }

  // --------------------------------------------------------------- 4. usage
  stdout.writeln("\n4. Today's usage");
  final usage = await client.usageToday();
  check(usage.day != null, 'the day parses', usage.day ?? '');
  check(
    usage.isUnlimited == (usage.remainingMinutes == null),
    'an unlimited budget reads as null remaining, not zero',
    'budget=${usage.budgetMinutes} remaining=${usage.remainingMinutes}',
  );
  check(
    usage.enforcerAgeSeconds != null,
    'enforcer_age_secs is carried — the only thing separating a quiet day from a '
        'dead enforcer',
    'age=${usage.enforcerAgeSeconds}s stale=${usage.enforcementMayBeStopped}',
  );

  // ---------------------------------------------------------- 5. the tier
  stdout.writeln('\n5. The screenshot is the PREVIEW tier');
  final preview = (await client.screenshotPreview(onTimer: true)).bytes;
  final previewSize = jpegSize(preview);
  check(
    previewSize != null,
    'the response is a JPEG',
    '${preview.length} bytes',
  );
  check(
    previewSize?.width == 960,
    'and its width is PREVIEW_W (960), so ?tier=preview was sent',
    '${previewSize?.width}x${previewSize?.height}',
  );

  // The audit keys on WHO ASKED, not on tier — a change that broke the old proxy. A
  // timer frame without `live` writes one screenshot_taken row per frame into a log that
  // rotates at 2 MiB, so this is trap 4 again through a different door.
  final audit = AuditLog.openOrNull(args);

  // The frames go out either way — they exercise the endpoint, which is worth doing even
  // when the log cannot be read. What changes is whether anything can be concluded.
  final rowsBefore = audit?.count('screenshot_taken');
  for (var i = 0; i < 5; i++) {
    await client.screenshotPreview(onTimer: true);
  }
  final rowsAfter = audit?.count('screenshot_taken');
  await client.screenshotPreview(onTimer: false);
  final rowsPerson = audit?.count('screenshot_taken');

  if (audit == null) {
    // Not a pass. With no log to read, both counts were 0 and the first assertion below
    // compared 0 to 0 and reported success — the check that defends trap 4 through the
    // audit door, succeeding precisely because it could see nothing.
    final why =
        'no audit log at ${args['audit'] ?? AuditLog.defaultPath} — pass --audit';
    skip('five timer frames added NO screenshot_taken rows', why);
    skip('and one person-requested frame added exactly one', why);
  } else {
    check(
      rowsAfter == rowsBefore,
      'five timer frames added NO screenshot_taken rows',
      'they coalesce into live_view; without live=1 this would be +5, and ~720 an hour',
    );
    check(
      rowsPerson == rowsAfter! + 1,
      'and one person-requested frame added exactly one',
      'a deliberate look at a child screen is meant to be on the record',
    );
  }

  // What the same call looks like WITHOUT the parameter — the trap, measured.
  final full = await rawShot(authority, client, '');
  final fullSize = jpegSize(full);
  check(
    fullSize != null && fullSize.width != previewSize?.width,
    'omitting ?tier= returns a DIFFERENT, larger frame — a valid JPEG either way, '
        'which is why only the size can tell',
    'no tier: ${fullSize?.width}x${fullSize?.height}, ${full.length} bytes  vs  '
        'preview: ${previewSize?.width}x${previewSize?.height}, '
        '${preview.length} bytes',
  );

  // ------------------------------------------------- 6. 401 reads as expired
  stdout.writeln('\n6. A lapsed session reads as sessionExpired');
  final anonymous = NestwatchClient(authority);
  for (final call in <(String, Future<Object?> Function())>[
    ('/api/time-requests', anonymous.timeRequests),
    ('/api/usage/today', anonymous.usageToday),
    ('/api/screenshot', () => anonymous.screenshotPreview(onTimer: true)),
  ]) {
    try {
      await call.$2();
      check(false, '${call.$1} refuses without a session');
    } on NestwatchException catch (e) {
      check(
        e.failure == NestwatchFailure.sessionExpired,
        '${call.$1} reports sessionExpired',
        e.failure.name,
      );
    }
  }

  finish(
    'All checks passed. Approve grants once, the tier is preview, and a lapsed '
              'session is named as one.',
  );
}

/// Fetch a screenshot with an arbitrary query, to demonstrate the trap the app avoids.
Future<List<int>> rawShot(
  String authority,
  NestwatchClient signedIn,
  String query,
) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('https://$authority/api/screenshot$query'),
    );
    final cookie = signedIn.cookie;
    if (cookie != null) req.cookies.add(cookie.toCookie());
    final res = await req.close();
    return (await res.toList()).expand((c) => c).toList();
  } finally {
    client.close(force: true);
  }
}
