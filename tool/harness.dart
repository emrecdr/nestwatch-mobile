/// What all eight `prove_*.dart` harnesses do around the checks they actually care about.
///
/// Each one declared its own `_failures` counter, its own `_check`, the same summary rule
/// and the same four-line argument parser — about twenty-five lines, copied eight times.
/// They had already started to drift: `prove_pin`'s `_check` was textually different from
/// the other seven while doing the same thing, which is the first symptom and the cheap
/// moment to catch it.
///
/// Worth sharing rather than tolerating, because these are the tools somebody reaches for
/// when the app is behaving strangely against a real PC. Eight harnesses that report
/// differently are eight things to re-learn at the moment you can least afford to.
///
/// Nothing here talks to a network. The harnesses do that themselves — this is only the
/// scaffolding around it.
library;

import 'dart:io';

int _failures = 0;
int _skipped = 0;

/// Record one check. [detail] is printed indented beneath, for evidence.
void check(bool ok, String label, [String detail = '']) {
  stdout.writeln(
    '  [${ok ? 'PASS' : 'FAIL'}] $label'
    '${detail.isEmpty ? '' : '\n         $detail'}',
  );
  if (!ok) _failures++;
}

/// Record a check that could not be run, and say why.
///
/// Only `prove_login` had this. Its token checks genuinely cannot always run — a pairing
/// token is single-use, so a harness that spends one has nothing to retry with — and it
/// grew a third outcome to say so. The other seven could report PASS or FAIL and nothing
/// else, which means an unrunnable check in any of them had to be silently dropped or
/// dishonestly passed.
///
/// Copy-paste spreads the code you had at the moment you copied. It cannot spread what
/// one copy worked out afterwards, which is the argument for this file.
void skip(String label, String why) {
  stdout.writeln('  [SKIP] $label\n         $why');
  _skipped++;
}

/// Print the verdict and leave. Exits 1 if anything failed, so a shell can tell.
///
/// Skips do not fail the run — a check that could not be run has not found anything
/// wrong — but they are stated above the verdict rather than under it, because
/// "everything passed" reads differently when three things never ran.
Never finish(String whenAllPassed) {
  stdout.writeln('\n${'-' * 70}');
  if (_skipped > 0) {
    stdout.writeln(
      '$_skipped check(s) SKIPPED — see above; coverage is incomplete.',
    );
  }
  stdout.writeln(
    _failures == 0 ? whenAllPassed : '$_failures check(s) FAILED.',
  );
  exit(_failures == 0 ? 0 : 1);
}

/// `--flag value` pairs, refusing what the hand-rolled copies took in silence.
///
/// The copied parser was `for (i = 0; i < argv.length - 1; i += 2)`, which drops a
/// trailing odd argument without a word — `--pin FP --real` ran with the default port and
/// said nothing. It also accepted any flag name, so a typo produced a null-check crash
/// somewhere further down rather than a sentence naming the flag.
///
/// A harness given the wrong arguments must not quietly run a different test from the one
/// asked for and then report PASS. Usage errors exit **2**, so "you invoked it wrong" is
/// distinguishable from "the thing under test failed".
Map<String, String> parseArgs(List<String> argv, {required Set<String> known}) {
  final usage = 'This harness takes: ${known.map((k) => '--$k').join(' ')}';

  if (argv.length.isOdd) {
    _die(
      'Arguments come in --flag value pairs, and there is an odd number of them.\n'
      'Nothing follows "${argv.last}".\n$usage',
    );
  }

  final args = <String, String>{};
  for (var i = 0; i < argv.length; i += 2) {
    final flag = argv[i];
    if (!flag.startsWith('--')) _die('Expected a --flag, got "$flag".\n$usage');
    final name = flag.substring(2);
    if (!known.contains(name)) _die('Unknown argument --$name.\n$usage');
    args[name] = argv[i + 1];
  }
  return args;
}

/// A required argument, or a sentence naming what is missing.
String requireArg(Map<String, String> args, String name) {
  final value = args[name];
  if (value == null) _die('Missing required argument --$name.');
  return value;
}

Never _die(String message) {
  stderr.writeln(message);
  exit(2);
}
