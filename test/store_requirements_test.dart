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

import 'support/source.dart';

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
      final source = readSourceOrFail(
        manifest,
        why: 'the manifest carries the declaration Play rejects for.',
      );
      expect(source, contains('android:name="isMonitoringTool"'));
      expect(source, contains('android:value="child_monitoring"'));
    });

    test('it sits inside <application>, where a meta-data tag is read', () {
      final source = readSourceOrFail(
        manifest,
        why: 'the manifest carries the declaration Play rejects for.',
      );
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
      final source = readSourceOrFail(
        'lib/src/ui/pairing_screen.dart',
        why: 'it is the only screen reachable without a paired PC.',
      );
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

  group('the privacy screen accounts for everything this app stores', () {
    // **Why a test and not care.** This list has drifted twice. The first time,
    // `unpair()` cleared two of the three items the screen promised it deleted. The
    // second time, `SecureSignInNotice` added a fourth Keystore key and the screen went
    // on naming three and saying "All three ... deletes all of them" — a false statement
    // about data handling, in the document Play requires to be truthful and now audits
    // against observed behaviour.
    //
    // What this can and cannot prove is worth being exact about. It cannot read the
    // sentences and judge whether they describe the key honestly; nothing can. It proves
    // only that a key cannot be **added in silence** — somebody has to write a bullet and
    // change a number word. `restore_test.dart` covers the other half, that `unpair()`
    // actually clears each one.
    const screen = 'lib/src/ui/privacy_screen.dart';

    /// Every distinct Keystore key literal under `lib/`.
    ///
    /// Matched on the naming convention every store here already follows —
    /// `'nestwatch.<name>.v<n>'` — rather than on the field name, because the constant
    /// holding it is private and named `_key` in four separate classes. A store that
    /// broke the convention would go uncounted, which is why the convention is stated in
    /// each store's own doc comment as well as here.
    Set<String> keystoreKeys() {
      final pattern = RegExp(r"'nestwatch\.[a-z_]+\.v\d+'");
      final found = <String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        found.addAll(
          pattern.allMatches(entity.readAsStringSync()).map((m) => m.group(0)!),
        );
      }
      return found;
    }

    /// The number words this copy is allowed to use, so a count change forces a copy
    /// change. Deliberately short: a privacy screen listing nine stored items has a
    /// bigger problem than a missing entry in this map.
    const words = <int, String>{
      1: 'one',
      2: 'two',
      3: 'three',
      4: 'four',
      5: 'five',
      6: 'six',
    };

    test('there is at least one key, so the count below is not vacuous', () {
      // The control. Every assertion after this compares two numbers, and two zeroes
      // agree perfectly while proving nothing at all.
      expect(
        keystoreKeys(),
        isNotEmpty,
        reason:
            'if this is empty the pattern stopped matching, and the rest of this '
            'group is agreeing about nothing',
      );
    });

    test('one bullet per stored item', () {
      final source = readSourceOrFail(
        screen,
        why: 'it is the in-app half of the policy Play requires.',
      );
      // The helper's own declaration is a `_bullet(` too, and it is not a bullet.
      final calls =
          RegExp(r'_bullet\(').allMatches(source).length -
          RegExp(r'_bullet\(ThemeData').allMatches(source).length;

      expect(
        calls,
        keystoreKeys().length,
        reason:
            'lib/ stores ${keystoreKeys().length} things in the Keystore and the '
            'privacy screen lists $calls. Whichever is newer, the screen has to say '
            'what it is — see this file\'s comment on why this is checked rather '
            'than remembered.',
      );
    });

    test('and the sentence that counts them says the same number', () {
      final source = readSourceOrFail(
        screen,
        why: 'it is the in-app half of the policy Play requires.',
      );
      final count = keystoreKeys().length;
      final word = words[count];
      expect(
        word,
        isNotNull,
        reason: '$count stored items has no word in this test\'s map',
      );
      expect(
        source,
        contains('All $word are held'),
        reason:
            'the summary sentence names a count, and it is the sentence that also '
            'promises they are encrypted, excluded from backup, and deleted by '
            '"Forget this PC" — so a wrong number there is wrong about all four claims',
      );
    });
  });
}
