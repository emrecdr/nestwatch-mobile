/// Talking to a live nestwatch, for the harnesses that need one.
///
/// Separate from `harness.dart`, which does the reporting and takes no network at all.
///
/// Both things here were written more than once, and in both cases the copies were not
/// equal — one had learned something the others had not, which is the ordinary way
/// copy-paste fails. It spreads the code you had at the moment you copied and cannot
/// spread what one copy worked out afterwards.
library;

import 'dart:convert';
import 'dart:io';

import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';

import 'harness.dart';

/// Sign in, or stop with a sentence that says which problem this is.
///
/// Existed at three strengths. `prove_login` told a rate-limited run that it was looking
/// at the harness environment rather than a defect, and a wrong password that nothing
/// below would mean anything. `prove_screens` printed `[STOP] ${e.message}` for every
/// failure, so a lockout produced a puzzle instead of the explanation its sibling already
/// knew how to give. `prove_background` had no handling at all and simply threw.
///
/// The limits come from [LoginLimits], so the sentence cannot outlive the numbers — and
/// those are checked against that PC's own source by `tool/check_golden.sh`.
Future<NestwatchClient> signInOrStop(String authority, String password) async {
  final client = NestwatchClient(authority);
  try {
    await client.login(password);
    return client;
  } on NestwatchException catch (e) {
    switch (e.failure) {
      case NestwatchFailure.rateLimited:
        stop(
          'That PC is rate-limited right now (${LoginLimits.maxAttempts} failures '
          'in ${LoginLimits.lockoutInWords()} locks an IP out).\n'
          '         This is the harness environment, not a defect. Wait '
          '${LoginLimits.lockoutInWords()} and re-run.',
        );
      case NestwatchFailure.badPassword:
        stop(
          '--password is not the control password for that PC.\n'
          '         Nothing below would mean anything, so this stops here.',
        );
      default:
        stop(e.message);
    }
  }
}

/// That PC's audit log, when there is one to read.
///
/// [openOrNull] returns null rather than an empty string, and the difference is the whole
/// reason this is a class. Both harnesses used to write
/// `audit.existsSync() ? count(...) : 0` inline, which turns "there is no log here" into
/// "the log contains nothing" — and a check comparing two such counts then passes.
/// `prove_screens` asserted that five timer frames add no `screenshot_taken` rows, and
/// with no log present that read 0 == 0 and reported PASS: the check defending trap 4
/// through the audit door, succeeding because it could not see anything.
///
/// Returning null makes the caller decide, and the only honest decision is [skip].
class AuditLog {
  static const String defaultPath = '/tmp/nestwatch-dev/audit.jsonl';

  final File _file;
  const AuditLog._(this._file);

  static AuditLog? openOrNull(Map<String, String> args) {
    final file = File(args['audit'] ?? defaultPath);
    return file.existsSync() ? AuditLog._(file) : null;
  }

  String get path => _file.path;

  /// Re-read on every call. The harnesses count rows either side of a request, so a
  /// snapshot taken once would compare a number against itself.
  int count(String event) =>
      RegExp(event).allMatches(_file.readAsStringSync()).length;

  bool mentions(String text) => _file.readAsStringSync().contains(text);
}

/// Post a time request the way the child's own LAN page does.
///
/// `jsonEncode` rather than string interpolation. The second copy of this built its body
/// by hand — `'{"minutes":$minutes,"reason":"$reason"}'` — which is malformed the moment
/// a reason contains a quote. It was only ever called with the literal `'proof run'`, so
/// it worked, which is how a copy stays broken.
Future<void> submitAsChild(String authority, int minutes, String reason) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('https://$authority/time-request'),
    );
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'minutes': minutes, 'reason': reason}));
    await (await req.close()).drain<void>();
  } finally {
    client.close(force: true);
  }
}
