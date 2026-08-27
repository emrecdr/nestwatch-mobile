/// Two Play requirements whose absence is invisible until a rejection.
///
/// Neither can be checked by running the app: it works perfectly without the monitoring
/// declaration, and it works perfectly with a policy nobody can reach. Both surface as an
/// upload being refused, days later, with the build long since forgotten.
///
/// Read from source for the same reason `flag_secure_test.dart` does, and with the same
/// rule: a file that cannot be read fails rather than skips.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const manifest = 'android/app/src/main/AndroidManifest.xml';

  group('the monitoring declaration', () {
    test('the manifest is where it lives, and it is readable', () {
      expect(
        File(manifest).existsSync(),
        isTrue,
        reason: 'nothing below was checked',
      );
    });

    test('isMonitoringTool is declared, with the value for a parental tool', () {
      // Play evaluates this against the store description and rejects apps that omit
      // it — and it must be present in every version code on every track, including the
      // first internal test upload.
      final source = File(manifest).readAsStringSync();
      expect(source, contains('android:name="isMonitoringTool"'));
      expect(source, contains('android:value="child_monitoring"'));
    });

    test('it sits inside <application>, where a meta-data tag is read', () {
      final source = File(manifest).readAsStringSync();
      final app = source.indexOf('<application');
      final flag = source.indexOf('isMonitoringTool');
      final close = source.indexOf('</application>');
      expect(app, greaterThan(-1));
      expect(flag, greaterThan(app));
      expect(
        flag,
        lessThan(close),
        reason: 'outside <application> it is not read',
      );
    });
  });

  group('the privacy policy is reachable without pairing', () {
    // Play requires the policy inside the app as well as in the Console. A reviewer has
    // no nestwatch to pair with, so a policy behind sign-in is one they cannot open —
    // and every screen past pairing requires a paired server.
    test('the pairing screen offers it', () {
      final source = File('lib/src/ui/pairing_screen.dart').readAsStringSync();
      expect(
        source,
        contains('PrivacyScreen.route()'),
        reason: 'the only screen reachable with no PC on the network',
      );
    });

    test('and the screen it opens exists', () {
      expect(File('lib/src/ui/privacy_screen.dart').existsSync(), isTrue);
    });
  });
}
