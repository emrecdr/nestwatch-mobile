/// iOS configuration that fails silently when it is wrong.
///
/// None of this can be caught by running the app. A background identifier missing from
/// `Info.plist` does not throw — iOS simply never schedules the task, and the parent hears
/// nothing, forever, with no error anywhere. A missing usage description does not throw
/// either; the permission is denied and, per PLAN §7, a local-network call attempted in
/// the background while the permission is undetermined "is denied silently without even
/// recording the denial".
///
/// So these are read from source, the same way `flag_secure_test.dart` reads the Kotlin,
/// and with the same rule: a file that cannot be read fails rather than skips.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source.dart';

void main() {
  const plistPath = 'ios/Runner/Info.plist';
  const pbxprojPath = 'ios/Runner.xcodeproj/project.pbxproj';
  const dartPath = 'lib/src/background/background_poll.dart';

  String plist() => readSourceOrFail(
    plistPath,
    why: 'Info.plist carries the iOS keys that fail silently.',
  );

  test('the iOS target exists and its Info.plist is readable', () {
    expect(
      File(plistPath).existsSync(),
      isTrue,
      reason:
          'nothing below was checked — if iOS was removed, remove this file too',
    );
  });

  test('the background task identifier matches the one Dart registers', () {
    // iOS refuses to schedule an identifier that is not declared, and says nothing. The
    // two live in different languages in different directories, which is exactly the
    // shape that drifts.
    final declared = RegExp(
      r'<key>BGTaskSchedulerPermittedIdentifiers</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist())?.group(1);
    expect(
      declared,
      isNotNull,
      reason: 'no BGTaskSchedulerPermittedIdentifiers at all',
    );

    final registered = RegExp(r"periodicTaskUniqueName = '([^']+)'")
        .firstMatch(
          readSourceOrFail(
            dartPath,
            why: 'it registers the identifier iOS must be told about.',
          ),
        )
        ?.group(1);
    expect(registered, isNotNull, reason: 'could not read the Dart identifier');

    expect(
      declared,
      contains(registered!),
      reason:
          'Info.plist does not declare the identifier registerPeriodicTask uses, so '
          'iOS will schedule nothing and report nothing',
    );
  });

  test('local network and camera both explain themselves', () {
    // Required for the permission prompt to appear at all. An empty or absent string is
    // an immediate rejection on submission, and a bad one is worse than that: this is the
    // sentence a parent reads when deciding whether to let the app reach their own PC.
    for (final key in [
      'NSLocalNetworkUsageDescription',
      'NSCameraUsageDescription',
    ]) {
      final value = RegExp(
        '<key>$key</key>\\s*<string>(.*?)</string>',
        dotAll: true,
      ).firstMatch(plist())?.group(1);
      expect(value, isNotNull, reason: '$key is missing');
      expect(
        value!.trim().length,
        greaterThan(30),
        reason: '$key must say why, not just that',
      );
    }
  });

  test('no ATS exception has been added', () {
    // Deliberate. The claim under test in integration_test/pinning_on_ios_test.dart is
    // that dart:io never consults ATS, so a self-signed certificate on a bare IP is
    // admitted or refused entirely by badCertificateCallback. An exception here would
    // make that test pass for the wrong reason and quietly weaken the app's TLS posture
    // for any future package that does use NSURLSession.
    expect(
      plist(),
      isNot(contains('NSAppTransportSecurity')),
      reason:
          'if this became necessary, the pinning proof needs re-reading first — an '
          'exception makes its result meaningless',
    );
  });

  test(
    'the bundle identifier matches Android, and is not the scaffold default',
    () {
      final project = readSourceOrFail(
        'ios/Runner.xcodeproj/project.pbxproj',
        why:
            'it carries the bundle identifier, which cannot change after a first upload.',
      );
      expect(
        project,
        contains('PRODUCT_BUNDLE_IDENTIFIER = com.nestwatch.mobile;'),
        reason:
            'must match android applicationId; neither can change after first upload',
      );
      expect(
        project,
        isNot(contains('com.nestwatch.nestwatchMobile;')),
        reason: 'the scaffold default stutters and was replaced',
      );
    },
  );

  group('the minimum iOS this app claims to run on', () {
    // **Three copies of one number, with nothing holding them together.** Xcode writes
    // `IPHONEOS_DEPLOYMENT_TARGET` once per build configuration — Debug, Release, Profile —
    // and a person raising it in the Xcode UI changes whichever one is selected. Two
    // agreeing and one not is a build that works locally and fails, or silently ships a
    // different floor, from whichever configuration CI happens to use.
    //
    // Nothing else in this repository checks it, and nothing about running the app would
    // reveal it: an app declaring iOS 14 simply installs on an iOS 14 device and crashes
    // there, or does not appear in the store listing for devices it should support.

    /// Every deployment target the Xcode project states.
    List<String> targets() {
      final source = readSourceOrFail(
        pbxprojPath,
        why:
            'it carries the minimum iOS version, once per build configuration.',
      );
      return RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
      ).allMatches(source).map((m) => m.group(1)!).toList();
    }

    test('there are some, so the checks below are not vacuous', () {
      // The control. An empty list satisfies "they all agree" perfectly.
      expect(
        targets(),
        isNotEmpty,
        reason:
            'if this is empty the setting was renamed or removed, and the rest of '
            'this group is agreeing about nothing',
      );
    });

    test('every build configuration states the same one', () {
      final found = targets();
      expect(
        found.toSet(),
        hasLength(1),
        reason:
            'Debug, Release and Profile disagreeing means the floor depends on '
            'which configuration built the artifact: $found',
      );
    });

    test('and it is at least 15.0, which Flutter 3.47 requires', () {
      // `docs/OPEN-FINDINGS.md` M21: 3.47 lifts the SDK's own floor from 13 to 15, so this
      // has to move before that upgrade rather than during it. Raised while this app has
      // never been released, which is the only moment dropping a supported OS version
      // costs nobody anything.
      final stated = double.parse(targets().first);
      expect(
        stated,
        greaterThanOrEqualTo(15.0),
        reason:
            'below 15.0 the Flutter 3.47 upgrade fails at build time, and the fix '
            'is here rather than in whatever error it produces',
      );
    });
  });
}
