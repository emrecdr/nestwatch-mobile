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

/// One thing to render, and the source file rendering it proves.
///
/// A record was enough while an entry was a builder and a string. It stopped being enough
/// when the closing test needed to know *which file* each case covers: that list used to
/// be retyped by hand below, so deleting a case here left the file still claiming to be
/// rendered, with nothing rechecking the claim. [file] makes the two impossible to
/// disagree -- the coverage list is now derived from the cases that actually run.
class _Subject {
  /// The basename under `lib/src/ui/`. Several subjects may name the same file: the three
  /// `Notice` tones are one widget rendered three ways.
  final String file;

  /// What the test is called. Distinct per case, unlike [file].
  final String label;

  final Widget Function() build;

  /// A string the render must actually put on screen. "Nothing was thrown" is an absence
  /// and passes for a screen that draws an empty box -- which is the exact failure this
  /// file exists to notice. Pairing it with a presence assertion makes the case fail
  /// closed.
  final String mustShow;

  const _Subject({
    required this.file,
    required this.label,
    required this.build,
    required this.mustShow,
  });
}

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

// Constructible without a signed-in client. The screens that need one are not skipped
// silently -- see the closing test, which names them.
// Each entry carries a string it must actually put on screen. "Nothing was thrown" is
// an absence and passes for a screen that renders an empty box -- which is the exact
// failure this file exists to notice. Pairing it with a presence assertion makes the
// case fail closed.
// Constructible without a signed-in client. The screens that need one are not skipped
// silently -- see the closing test, which names them.
final _subjects = <_Subject>[
  _Subject(
    file: 'privacy_screen.dart',
    label: 'PrivacyScreen',
    build: () => const PrivacyScreen(),
    mustShow: 'Privacy',
  ),
  _Subject(
    file: 'fingerprint_view.dart',
    label: 'FingerprintView',
    build: () => FingerprintView(
      Fingerprint.parse(
        'E0:60:A4:A5:83:F3:49:7C:F2:21:2C:33:39:E4:04:03:'
        '24:ED:72:FE:4F:67:E4:1B:54:E3:FF:84:1A:47:0D:AA',
      ),
    ),
    mustShow: 'E0',
  ),
  _Subject(
    file: 'notice.dart',
    label: 'Notice (warning, the longest one shipped)',
    build: () => const Notice(
      'That PC refused the connection because this phone does not look like it is '
      'on the same home network. If a VPN is switched on, turn it off.',
      tone: NoticeTone.warning,
      icon: Icons.warning_amber_rounded,
    ),
    mustShow: 'same home network',
  ),
  _Subject(
    file: 'notice.dart',
    label: 'Notice (advisory)',
    build: () => const Notice(
      'Screenshots are off on that PC.',
      tone: NoticeTone.advisory,
    ),
    mustShow: 'Screenshots are off',
  ),
  _Subject(
    file: 'notice.dart',
    label: 'Notice (plain)',
    build: () => const Notice('Ask on the PC itself.'),
    mustShow: 'Ask on the PC itself',
  ),
  _Subject(
    file: 'notice.dart',
    label: 'Notice (dismissible, carrying the real curfew note)',
    // The exact sentence nestwatch 0.5.1 sends, captured off the wire on 2026-09-02 --
    // not a shortened stand-in. It is the longest string this widget will be asked to
    // render, it now shares its row with a close button, and 320 logical pixels is the
    // narrowest screen the app claims. That combination is where a `Row` overflows, and
    // an overflow here would land on top of the one message this app has that exists
    // solely to stop a parent believing something untrue.
    build: () => Notice(
      'Bedtime is in force now, so the PC will still shut down — screen time and '
      'bedtime are separate limits. Use "Later bedtime tonight" on the Curfew card '
      'to move bedtime itself.',
      tone: NoticeTone.warning,
      icon: Icons.bedtime,
      onDismiss: () {},
    ),
    mustShow: 'separate limits',
  ),
  // The largest file in `lib/src/ui/` (439 lines) and the first thing a parent sees.
  // It needs only a controller, and every one of that controller's collaborators has
  // an in-memory implementation already -- the same set `restore_test.dart` uses.
  _Subject(
    file: 'pairing_screen.dart',
    label: 'PairingScreen (nothing paired yet)',
    build: () => PairingScreen(
      controller: PairingController(
        overrides: PinnedHttpOverrides(),
        identities: InMemoryServerIdentityStore(),
        sessions: InMemorySessionStore(),
        forgetAnnounced: InMemorySeenRequestStore().clear,
      ),
    ),
    mustShow: 'nestwatch',
  ),
];

void main() {
  // Every case below asserts an *absence* -- "nothing was thrown". That is the direction
  // that fails open: a pump that silently builds nothing passes just as quietly as one
  // that builds correctly. So the rig is shown to catch both faults it claims to catch
  // before any real screen is trusted to it.
  group('the rig can fail', () {
    testWidgets('a widget that throws while building is caught', (
      tester,
    ) async {
      await _render(
        tester,
        Builder(builder: (_) => throw StateError('planted')),
        _sizes.values.first,
      );
      final caught = tester.takeException();
      expect(
        caught,
        isA<StateError>(),
        reason:
            'if this is null the pump is not building, and every pass below is empty',
      );
    });

    testWidgets('a column taller than the screen is caught', (tester) async {
      await _render(
        tester,
        Column(
          children: List.filled(
            40,
            const SizedBox(height: 40, child: Text('x')),
          ),
        ),
        _sizes.values.first,
      );
      expect(
        tester.takeException(),
        isNotNull,
        reason:
            'overflow must reach takeException, or the size cases below prove nothing',
      );
    });
  });

  group('screens build and lay out', () {
    for (final size in _sizes.entries) {
      for (final subject in _subjects) {
        testWidgets('${subject.label} on a ${size.key}', (tester) async {
          await _render(tester, Center(child: subject.build()), size.value);
          expect(
            tester.takeException(),
            isNull,
            reason: 'threw or overflowed while building',
          );
          expect(
            find.textContaining(subject.mustShow, findRichText: true),
            findsWidgets,
            reason:
                'built without throwing, but put "${subject.mustShow}" on screen nowhere',
          );
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
      'home_screen.dart':
          'needs a NestwatchClient and opens an event stream on init',
      'screenshot_screen.dart':
          'needs a NestwatchClient; the body is JPEG bytes off the PC',
      'usage_screen.dart': 'built by PolledScreen against a live client',
      'time_codes_screen.dart': 'built by PolledScreen against a live client',
      'time_requests_screen.dart':
          'built by PolledScreen against a live client',
      'polled_screen.dart':
          'the generic that drives the four above; needs their client',
      'notifications_sheet.dart':
          'needs a permission authority backed by a platform channel',
      'scan_screen.dart': 'needs the camera platform channel (mobile_scanner)',
      'background_promise.dart':
          'needs WorkManager registration, which is a platform channel',
      'screen_load.dart': 'pure logic, covered by screen_load_test.dart',
      'frame_label.dart': 'pure logic, covered by frame_label_test.dart',
      'refusal_lines.dart': 'pure logic, covered by refusal_lines_test.dart',
      'relative_time.dart': 'pure logic, covered by relative_time_test.dart',
      'poller.dart':
          'pure logic, covered by poller_test.dart and two mutations',
    };
    // Derived, never retyped. This used to be four literal filenames sitting beside the
    // cases they described -- the rot this group exists to prevent, reproduced forty lines
    // below the comment warning about it: delete a `testWidgets` case and its filename
    // kept claiming to be rendered, with nothing left to recheck the claim.
    final rendered = _subjects.map((s) => s.file).toSet();

    test('every file under lib/src/ui is either rendered here or named above', () {
      final files = Directory('lib/src/ui')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.dart'))
          .toSet();

      // The scan must be able to see something before its silence means anything.
      expect(
        files,
        isNotEmpty,
        reason: 'lib/src/ui read as empty -- the check is blind',
      );
      expect(
        files,
        contains('home_screen.dart'),
        reason:
            'a known file is missing, so this listing is not reading the real tree',
      );

      // A file in both lists is a self-contradiction, and comparing each against the
      // directory listing cannot see it: both memberships are individually plausible.
      expect(
        rendered.intersection(notRendered.keys.toSet()),
        isEmpty,
        reason: 'listed as both rendered and not rendered',
      );

      final unaccounted = files
          .difference(rendered)
          .difference(notRendered.keys.toSet());
      expect(
        unaccounted,
        isEmpty,
        reason:
            'new screen(s) with no rendering test and no stated reason: $unaccounted',
      );

      // And the reverse: a name that no longer exists is a reason nobody has revisited.
      final stale = rendered.union(notRendered.keys.toSet()).difference(files);
      expect(stale, isEmpty, reason: 'listed but no longer present: $stale');
    });
  });
}
