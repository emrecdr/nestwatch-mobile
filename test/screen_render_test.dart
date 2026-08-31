/// Does a screen render at all?
///
/// Before this file, `test/` contained 253 tests and not one `testWidgets` — measured
/// 2026-08-31, zero occurrences of `testWidgets(` or `pumpWidget` anywhere under `test/`
/// or `integration_test/`. `lib/src/ui/` is 2,574 lines, and every one of them was checked
/// only by reading. `screen_load_test.dart` says as much in its own header and answers it
/// by extracting one rule out of four screens into pure logic; that closed the rule, not
/// the rendering.
///
/// **What this does not claim.** It would not have caught the blank white screen on iOS.
/// That was `initNotifications()` throwing from `main()` before any screen existed, and
/// pumping a screen directly never calls `main()`. A screenshot found that one and a
/// screenshot is still what would find the next of its kind. What this closes is narrower
/// and was genuinely open: a screen that throws while building, or overflows on a small
/// phone, now fails here instead of on a parent's handset.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'package:nestwatch_mobile/src/ui/fingerprint_view.dart';
import 'package:nestwatch_mobile/src/ui/notice.dart';
import 'package:nestwatch_mobile/src/ui/pairing_screen.dart';
import 'package:nestwatch_mobile/src/ui/privacy_screen.dart';

/// The smallest screen this app claims to support, and a large one.
///
/// Both, because overflow is a function of height: a column that fits a Pixel 7 can still
/// overflow an iPhone SE, and testing one size is how that ships. 320x568 is the iPhone SE
/// (1st gen) in logical pixels -- the floor for the iOS 14 deployment target in
/// `ios/Runner/Info.plist`.
const _sizes = <String, Size>{
  'small phone (320x568)': Size(320, 568),
  'large phone (430x932)': Size(430, 932),
};

Future<void> _render(WidgetTester tester, Widget child, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pump();
}

void main() {
  // Every case below asserts an *absence* -- "nothing was thrown". That is the direction
  // that fails open: a pump that silently builds nothing passes just as quietly as one
  // that builds correctly. So the rig is shown to catch both faults it claims to catch
  // before any real screen is trusted to it.
  group('the rig can fail', () {
    testWidgets('a widget that throws while building is caught', (tester) async {
      await _render(tester, Builder(builder: (_) => throw StateError('planted')),
          _sizes.values.first);
      final caught = tester.takeException();
      expect(caught, isA<StateError>(),
          reason: 'if this is null the pump is not building, and every pass below is empty');
    });

    testWidgets('a column taller than the screen is caught', (tester) async {
      await _render(
        tester,
        Column(children: List.filled(40, const SizedBox(height: 40, child: Text('x')))),
        _sizes.values.first,
      );
      expect(tester.takeException(), isNotNull,
          reason: 'overflow must reach takeException, or the size cases below prove nothing');
    });
  });

  group('screens build and lay out', () {
    // Constructible without a signed-in client. The screens that need one are not skipped
    // silently -- see the closing test, which names them.
    // Each entry carries a string it must actually put on screen. "Nothing was thrown" is
    // an absence and passes for a screen that renders an empty box -- which is the exact
    // failure this file exists to notice. Pairing it with a presence assertion makes the
    // case fail closed.
    final subjects = <String, (Widget Function(), String)>{
      'PrivacyScreen': (() => const PrivacyScreen(), 'Privacy'),
      'FingerprintView': (
        () => FingerprintView(
              Fingerprint.parse(
                'E0:60:A4:A5:83:F3:49:7C:F2:21:2C:33:39:E4:04:03:'
                '24:ED:72:FE:4F:67:E4:1B:54:E3:FF:84:1A:47:0D:AA',
              ),
            ),
        'E0',
      ),
      'Notice (warning, the longest one shipped)': (
        () => const Notice(
              'That PC refused the connection because this phone does not look like it is '
              'on the same home network. If a VPN is switched on, turn it off.',
              tone: NoticeTone.warning,
              icon: Icons.warning_amber_rounded,
            ),
        'same home network',
      ),
      'Notice (advisory)': (
        () => const Notice('Screenshots are off on that PC.', tone: NoticeTone.advisory),
        'Screenshots are off',
      ),
      'Notice (plain)': (
        () => const Notice('Ask on the PC itself.'),
        'Ask on the PC itself',
      ),
      // The largest file in `lib/src/ui/` (439 lines) and the first thing a parent sees.
      // It needs only a controller, and every one of that controller's collaborators has
      // an in-memory implementation already -- the same set `restore_test.dart` uses.
      'PairingScreen (nothing paired yet)': (
        () => PairingScreen(
              controller: PairingController(
                overrides: PinnedHttpOverrides(),
                identities: InMemoryServerIdentityStore(),
                sessions: InMemorySessionStore(),
                forgetAnnounced: InMemorySeenRequestStore().clear,
              ),
            ),
        'nestwatch',
      ),
    };

    for (final size in _sizes.entries) {
      for (final subject in subjects.entries) {
        final (build, mustShow) = subject.value;
        testWidgets('${subject.key} on a ${size.key}', (tester) async {
          await _render(tester, Center(child: build()), size.value);
          expect(tester.takeException(), isNull,
              reason: 'threw or overflowed while building');
          expect(find.textContaining(mustShow, findRichText: true), findsWidgets,
              reason: 'built without throwing, but put "$mustShow" on screen nowhere');
        });
      }
    }
  });

  // What is NOT rendered, kept as a failing-closed list rather than a comment.
  //
  // A note saying "the rest needs a client" is true the day it is written and silently
  // wrong the day someone adds a screen. This reads `lib/src/ui/` instead, and a file in
  // neither list fails until somebody decides which it is -- so the gap stays measured.
  group('the uncovered screens stay named', () {
    // Reasons, not just names. Each says what stands between the file and a pump.
    const notRendered = <String, String>{
      'home_screen.dart': 'needs a NestwatchClient and opens an event stream on init',
      'screenshot_screen.dart': 'needs a NestwatchClient; the body is JPEG bytes off the PC',
      'usage_screen.dart': 'built by PolledScreen against a live client',
      'time_codes_screen.dart': 'built by PolledScreen against a live client',
      'time_requests_screen.dart': 'built by PolledScreen against a live client',
      'polled_screen.dart': 'the generic that drives the four above; needs their client',
      'notifications_sheet.dart': 'needs a permission authority backed by a platform channel',
      'scan_screen.dart': 'needs the camera platform channel (mobile_scanner)',
      'background_promise.dart': 'needs WorkManager registration, which is a platform channel',
      'screen_load.dart': 'pure logic, covered by screen_load_test.dart',
      'relative_time.dart': 'pure logic, covered by relative_time_test.dart',
      'poller.dart': 'pure logic, covered by poller_test.dart and two mutations',
    };
    const rendered = <String>{
      'privacy_screen.dart',
      'fingerprint_view.dart',
      'notice.dart',
      'pairing_screen.dart',
    };

    test('every file under lib/src/ui is either rendered here or named above', () {
      final files = Directory('lib/src/ui')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.dart'))
          .toSet();

      // The scan must be able to see something before its silence means anything.
      expect(files, isNotEmpty, reason: 'lib/src/ui read as empty -- the check is blind');
      expect(files, contains('home_screen.dart'),
          reason: 'a known file is missing, so this listing is not reading the real tree');

      final unaccounted = files.difference(rendered).difference(notRendered.keys.toSet());
      expect(unaccounted, isEmpty,
          reason: 'new screen(s) with no rendering test and no stated reason: $unaccounted');

      // And the reverse: a name that no longer exists is a reason nobody has revisited.
      final stale = rendered.union(notRendered.keys.toSet()).difference(files);
      expect(stale, isEmpty, reason: 'listed but no longer present: $stale');
    });
  });
}
