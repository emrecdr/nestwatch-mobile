/// Reading a file the compiler cannot check, without letting the check disappear.
///
/// Seven test files were doing this, each re-implementing the same rule. The rule is the
/// valuable part, not the reading: **a file that cannot be found must fail, never skip.**
///
/// Source-scraping is the right altitude for these particular facts, and worth saying so
/// because it usually is not. A `FLAG_SECURE` window flag, an `isMonitoringTool` manifest
/// declaration and a `BGTaskSchedulerPermittedIdentifiers` entry have no runtime handle a
/// headless test can reach — and all three fail *silently* in production. The app works
/// perfectly without them right up until a thumbnail leaks, an upload is rejected, or iOS
/// schedules nothing and says nothing.
///
/// So the check has to live somewhere, and the only somewhere available is the text.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The contents of [path], or a failed test naming what went unchecked.
///
/// [why] should say what the file is for, because the failure a reader meets is usually
/// "somebody moved it" and the useful next step is to point the test at the new place
/// rather than delete it.
String readSourceOrFail(String path, {required String why}) {
  final file = File(path);
  if (!file.existsSync()) {
    fail(
      'Could not read $path.\n'
      '  $why\n'
      '  Nothing was checked — which is not the same as nothing being wrong. If the '
      'file moved, point this at the new path rather than removing the test.',
    );
  }
  return file.readAsStringSync();
}
