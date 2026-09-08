/// The two data tabs nothing ever drew, drawn against real server output.
///
/// `docs/OPEN-FINDINGS.md` M19's finding was that the suite "tests logic thoroughly and
/// draws nothing", and the reason recorded against these two was that they need a live
/// `NestwatchClient`. That was never the barrier it read as — three other screens are
/// already pumped against a TLS stub on loopback. What they needed was a rig, and this is
/// the same one `later_bedtime_test.dart` and `lock_screen_test.dart` use.
///
/// ## Why the bodies come out of `test/golden/`
///
/// A hand-written payload cannot be wrong about itself. That is `M26`'s shape — the input
/// derives from the thing under test, so it cannot see it change — and it is why the
/// `_curfewNote` test that built its object by hand is recorded as a defect rather than as
/// coverage. These are the vendored captures of what nestwatch actually sends, checked
/// against that PC by `tool/check_golden.sh` on every push, so a field that changes shape
/// over there reaches these assertions rather than sliding past them.
///
/// Read as data rather than through `readSourceOrFail`, per `M3`: a missing file already
/// throws where it is used, and a helper whose whole purpose is a nicer message would be
/// ceremony.
///
/// ## Both directions, every case
///
/// "Nothing was thrown" is an absence and passes just as quietly for a screen that renders
/// an empty box, which is the exact failure `screen_render_test.dart` exists to notice. So
/// every case here also names something the screen must actually put on the screen, and
/// the two `usage-today` captures are asserted *against each other*: the refusals section
/// is present on the day there were refusals and absent on the day there were none.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'package:nestwatch_mobile/src/ui/refusal_lines.dart';
import 'package:nestwatch_mobile/src/ui/time_codes_screen.dart';
import 'package:nestwatch_mobile/src/ui/usage_screen.dart';

import 'support/certs.dart';

/// Small first: the dense screen overflows on the small one or nowhere.
const _sizes = <String, Size>{
  'small phone (320x568)': Size(320, 568),
  'large phone (430x932)': Size(430, 932),
};

String _golden(String name) => File('test/golden/$name').readAsStringSync();

void main() {
  const dir = fixtureDir;
  late HttpServer server;
  late NestwatchClient client;

  /// What the stub answers for each path. Set per test, before the screen is pumped.
  late Map<String, String> bodies;

  setUp(() async {
    bodies = {
      '/api/usage/today': _golden('usage-today.json'),
      '/api/time-codes': _golden('time-codes.json'),
    };

    final context = SecurityContext()
      ..useCertificateChain('$dir/server.cert.pem')
      ..usePrivateKey('$dir/server.key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) async {
      final response = request.response..statusCode = 200;
      response.write(bodies[request.uri.path] ?? '{}');
      await response.close();
    });

    HttpOverrides.global = PinnedHttpOverrides(
      pin: fingerprintOf('$dir/server.cert.pem'),
    );
    client = NestwatchClient('127.0.0.1:${server.port}');
  });

  tearDown(() async {
    client.close();
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  /// Pump [screen] at [size] and let the real socket finish.
  ///
  /// A fixed pause rather than a poll, for the reason `lock_screen_test.dart` gives: the
  /// server is in this process on loopback and answers immediately, and if this ever goes
  /// flaky the honest fix is to wait on the request rather than to lengthen the sleep.
  Future<void> show(WidgetTester tester, Widget screen, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: screen)));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }

  Widget usage() =>
      UsageScreen(client: client, visible: true, onFailure: (_) {});
  Widget codes() =>
      TimeCodesScreen(client: client, visible: true, onFailure: (_) {});

  group('the usage tab draws a real day', () {
    for (final size in _sizes.entries) {
      testWidgets('on a ${size.key}', (tester) async {
        await tester.runAsync(() async {
          await show(tester, usage(), size.value);

          expect(
            tester.takeException(),
            isNull,
            reason: 'threw or overflowed while building',
          );
          // Every one of these is a number out of the captured payload rather than a
          // string this test chose: used_mins 55, extra_mins 15, and a page title with
          // punctuation and spaces in it.
          expect(find.textContaining('55 min used today'), findsWidgets);
          expect(
            find.textContaining('Includes 15 extra minutes'),
            findsWidgets,
          );
          expect(
            find.textContaining('Poki - Free Online Games'),
            findsWidgets,
            reason:
                'the pages list is the part furthest down the screen, so this is '
                'also the assertion that the whole thing laid out',
          );
        });
      });
    }

    testWidgets('and shows what was refused, on a day there was any', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await show(tester, usage(), _sizes.values.last);
        expect(find.textContaining(refusalsTitle), findsWidgets);
      });
    });

    testWidgets('and hides it on a day there was none', (tester) async {
      // The other captured day: `refused_total` 0, `focus_missing` true, every list
      // empty. Its own comment in usage_screen.dart is that "a card that reads '0, 0, 0'
      // every evening is a card that stops being read".
      bodies['/api/usage/today'] = _golden('usage-today-unmeasured.json');
      await tester.runAsync(() async {
        await show(tester, usage(), _sizes.values.last);

        expect(tester.takeException(), isNull);
        expect(find.textContaining('10 min used today'), findsWidgets);
        expect(
          find.textContaining(refusalsTitle),
          findsNothing,
          reason:
              'shown on the other capture and not on this one — which is what makes '
              'the assertion above mean something',
        );
        expect(
          find.textContaining('the watcher is not reporting'),
          findsWidgets,
          reason:
              'focus_missing is true here, and an empty list with no explanation '
              'reads as "nothing was used"',
        );
        // Added because the mutation audit caught its absence: widening the guard from
        // `> 0` to `>= 0` survived, so nothing defended the claim that this line is for
        // the days there is something to say. It is the same argument the refusals
        // section makes one field down — a line that reads "Includes 0" every evening is
        // a line that stops being read.
        expect(
          find.textContaining('extra minutes'),
          findsNothing,
          reason:
              'extra_mins is 0 on this capture, and the other one proves the line '
              'appears when there is something to report',
        );
      });
    });
  });

  group('the time-codes tab keeps the code covered', () {
    for (final size in _sizes.entries) {
      testWidgets('on a ${size.key}', (tester) async {
        await tester.runAsync(() async {
          await show(tester, codes(), size.value);

          expect(
            tester.takeException(),
            isNull,
            reason: 'threw or overflowed while building',
          );
          expect(find.textContaining('45 minutes'), findsWidgets);
        });
      });
    }

    testWidgets('a code is masked until somebody asks for it', (tester) async {
      await tester.runAsync(() async {
        await show(tester, codes(), _sizes.values.last);

        // The security property, rendered rather than read. Anyone who sees the code
        // can spend it, so revealing is a deliberate act.
        expect(
          find.text('K7M2QF'),
          findsNothing,
          reason:
              'the code out of the capture is on screen before it was asked for',
        );
        expect(
          find.text('••••••'),
          findsOneWidget,
          reason:
              'six dots for a six-character code — the mask is derived from the code '
              'because nestwatch owns that length and moved it from 8 to 6 once',
        );

        await tester.tap(find.byTooltip('Show'));
        await tester.pump();

        expect(
          find.text('K7M2QF'),
          findsOneWidget,
          reason:
              'and the control: if this fails the assertion above passes for a screen '
              'that renders no code at all',
        );
      });
    });

    testWidgets('and draws a day with no codes on it', (tester) async {
      bodies['/api/time-codes'] = _golden('time-codes-empty.json');
      await tester.runAsync(() async {
        await show(tester, codes(), _sizes.values.last);

        expect(tester.takeException(), isNull);
        expect(
          find.textContaining('Leave a code'),
          findsWidgets,
          reason: 'the minting half stands alone when there is nothing to list',
        );
      });
    });
  });
}
