/// The window flag that keeps a child's desktop out of the recents thumbnail.
///
/// A window flag has no headless test — nothing here can observe Android compositing a
/// snapshot. What this *can* do is refuse to let the line be deleted quietly, which is
/// the failure that would otherwise look like nothing at all: the app keeps working,
/// every test keeps passing, and the frame starts appearing in the app switcher again.
///
/// It reads the Kotlin the same way `tool/check_golden.sh` reads nestwatch's Rust, and
/// with the same discipline — a file it cannot find fails rather than skips. A guard that
/// silently stops guarding is the specific defect this repo keeps finding in itself.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const path =
      'android/app/src/main/kotlin/com/nestwatch/mobile/MainActivity.kt';

  test('MainActivity is where FLAG_SECURE lives, and it is readable', () {
    expect(
      File(path).existsSync(),
      isTrue,
      reason:
          'MainActivity moved or was renamed. Nothing below was checked — point this '
          'test at the new path rather than deleting it.',
    );
  });

  test('the activity sets FLAG_SECURE', () {
    final source = File(path).readAsStringSync();
    expect(
      source,
      contains('WindowManager.LayoutParams.FLAG_SECURE'),
      reason:
          'Without it Android snapshots the current screen for the recents list, and '
          'the Screen tab is a live picture of a child desktop.',
    );
  });

  test('it is set as both flag and mask, which is what actually enables it', () {
    // `setFlags(flags, mask)` only touches the bits named in the mask. Passing the flag
    // as the value with an empty mask compiles, runs, and does nothing — so the mistake
    // this asserts against is a silent one.
    final source = File(path).readAsStringSync();
    final calls = RegExp(
      r'setFlags\(\s*WindowManager\.LayoutParams\.FLAG_SECURE\s*,\s*WindowManager\.LayoutParams\.FLAG_SECURE\s*,?\s*\)',
    );
    expect(
      calls.hasMatch(source),
      isTrue,
      reason: 'FLAG_SECURE must be passed as both the value and the mask',
    );
  });

  test('it is set in onCreate, before the first frame can be composited', () {
    final source = File(path).readAsStringSync();
    final onCreate = source.indexOf('onCreate');
    final setFlags = source.indexOf('setFlags');
    expect(onCreate, greaterThan(-1), reason: 'no onCreate to set it in');
    expect(
      setFlags,
      greaterThan(onCreate),
      reason: 'setting it after the window is up leaves a capturable frame',
    );
  });
}
