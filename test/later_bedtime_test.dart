/// Making the server's own instruction true on this screen.
///
/// `curfew_note` arrives after an approve and ends:
///
///     Use "Later bedtime tonight" on the Curfew card to move bedtime itself.
///
/// Every word of that was true and none of it was reachable. There is no Curfew card on a
/// phone — `PLAN.md` §5 kept curfew in the browser as configuration — so the app was
/// telling a parent something correct and pointing them at a device they may not be near.
/// `docs/OPEN-FINDINGS.md` M24 argues the fix is to make the sentence true here rather
/// than to paraphrase a verdict that PC computed against its own trusted clock, which is
/// the comparison `M6` and `nestwatch#O72` exist to stop clients making.
///
/// ## The first test is the one that will age
///
/// The button's label is not this app's copy to choose: it is quoted from a sentence
/// written in someone else's repository. So it is asserted against a note **captured off
/// the wire**, not against a string retyped here. If nestwatch rewrites that sentence, the
/// coupling breaks here rather than silently on a parent's phone, where the symptom is a
/// person reading an instruction and hunting for a control that no longer matches it.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'package:nestwatch_mobile/src/ui/time_requests_screen.dart';

import 'support/certs.dart';

/// Copied off the wire, not composed: a dev nestwatch was installed on a throwaway port
/// on 2026-09-02, a curfew window covering the current time was set through
/// `POST /api/curfew`, and a request was submitted and approved. Reproduced byte for byte,
/// typographic dash included, and identical to the copy `api_wire_test.dart` asserts on.
const String capturedCurfewNote =
    'Bedtime is in force now, so the PC will still shut down — screen time '
    'and bedtime are separate limits. Use "Later bedtime tonight" on the '
    'Curfew card to move bedtime itself.';

void main() {
  test(
    'the control is named by the sentence that sends a parent looking for it',
    () {
      // The whole coupling, in one line. `laterBedtimeLabel` exists so this is greppable
      // from both ends rather than being four words repeated in a widget.
      expect(
        capturedCurfewNote,
        contains(laterBedtimeLabel),
        reason:
            'the note tells a parent to use a control by name; a button called '
            'anything else leaves them still looking for it',
      );
    },
  );

  group('what the parent is told, once bedtime has moved', () {
    test('the server formatted the time, so this repeats it', () {
      expect(
        bedtimeConfirmation(const CurfewExtension(minutes: 30, until: '23:30')),
        'Bedtime is 23:30 tonight.',
      );
    });

    test('and when it said no time, this says how much instead', () {
      // Reachable: `extend_curfew` formats with `unwrap_or_default()`, so a blank string
      // is a real wire shape and `nonEmptyString` turns it into null here. The wrong
      // answer would be "Bedtime is  tonight." — the second-wrong one would be this phone
      // computing now + 30 and disagreeing with the clock that enforces bedtime.
      expect(
        bedtimeConfirmation(const CurfewExtension(minutes: 45)),
        'Bedtime moved back 45 minutes tonight.',
      );
    });

    test('the minutes come from the answer, not from the request', () {
      // Echoed back by the server. A phone that reported what it *asked* for would tell a
      // parent a clamped or adjusted extension had done what they wanted.
      expect(
        bedtimeConfirmation(const CurfewExtension(minutes: 15)),
        contains('15'),
      );
    });
  });

  test('the offered extensions need no copy of a server constant', () {
    // `extend_curfew` validates against `timereq::MAX_REQUEST_MINUTES` (240) and
    // `limits.json` does not publish it — re-checked 2026-09-06. A free-entry field would
    // need this app to hold that number, which is the fifth reader M6 is open to delete.
    // These are a product choice that happens to sit well inside any plausible cap; the
    // assertion is that they stay that way, not that they mirror anything.
    expect(laterBedtimeChoices, isNotEmpty);
    for (final minutes in laterBedtimeChoices) {
      expect(minutes, greaterThan(0));
      expect(
        minutes,
        lessThanOrEqualTo(120),
        reason:
            'a preset near the cap would be a copy of it, and would need the '
            'constant this app deliberately does not hold',
      );
    }
  });

  group('the flow, through a real request', () {
    const dir = fixtureDir;
    late HttpServer server;
    late NestwatchClient client;
    final seen = <String>[];

    /// What the stub puts in `budget_note` on the extension.
    ///
    /// nestwatch computes this because `extend_curfew` shipped "with the opposite hole"
    /// from `curfew_note`: a parent whose child has no screen time left can push bedtime
    /// back, be told it worked, and watch the PC lock anyway. Showing it is the reason
    /// this app is allowed to offer the control at all.
    String? budgetNote;

    setUp(() async {
      seen.clear();
      budgetNote = null;
      final context = SecurityContext()
        ..useCertificateChain('$dir/server.cert.pem')
        ..usePrivateKey('$dir/server.key.pem');
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server.listen((request) async {
        seen.add('${request.method} ${request.uri.path}');
        final response = request.response..statusCode = 200;
        switch (request.uri.path) {
          case '/api/time-requests':
            response.write(
              '[{"id":"r1","ts":"2026-09-06T20:00:00Z","minutes":30,'
              '"reason":"one more level"}]',
            );
          case '/api/time-requests/r1/approve':
            response.write(
              '{"ok":true,"minutes":30,"curfew_note":'
              '${_json(capturedCurfewNote)}}',
            );
          case '/api/curfew/extend':
            response.write(
              '{"ok":true,"minutes":30,"until":"23:30","budget_note":'
              '${budgetNote == null ? 'null' : _json(budgetNote!)}}',
            );
          default:
            response.write('{"ok":true}');
        }
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

    Widget subject() => MaterialApp(
      home: Scaffold(
        body: TimeRequestsScreen(
          client: client,
          visible: true,
          onFailure: (_) {},
        ),
      ),
    );

    /// Let the real socket finish **and** any animation run to its end.
    ///
    /// Both halves are needed and they are not the same thing. The request goes over an
    /// actual TLS connection, which only moves in real time — hence the `delayed`. The
    /// modal sheet moves on Flutter's *fake* clock, which `pump()` with no argument does
    /// not advance at all, so without the second pump its buttons are still off-screen and
    /// mid-transition when the next `tap` looks for them. `pumpAndSettle` would do it and
    /// throws inside `runAsync`, which is why this is written out.
    ///
    /// 500ms is comfortably past Material's bottom-sheet duration; the assertion that the
    /// sheet is really there is the `tap` that follows, which fails loudly if it is not.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    }

    testWidgets('the control appears with the note, and not before', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);

        expect(find.text('30 more minutes'), findsOneWidget);
        expect(
          find.text(laterBedtimeLabel),
          findsNothing,
          reason:
              'with no note on screen this would be a Curfew card, which §5 kept '
              'in the browser — the note is what makes the control legible',
        );

        await tester.tap(find.text('Approve'));
        await settle(tester);

        expect(find.textContaining('Bedtime is in force now'), findsOneWidget);
        expect(find.text(laterBedtimeLabel), findsOneWidget);
      });
    });

    testWidgets('choosing an extension reaches the endpoint', (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);
        await tester.tap(find.text('Approve'));
        await settle(tester);

        await tester.tap(find.text(laterBedtimeLabel));
        await settle(tester);
        await tester.tap(find.text('30 min'));
        await settle(tester);

        expect(seen, contains('POST /api/curfew/extend'));
      });
    });

    testWidgets('a budget note replaces it, because it is the new true caveat', (
      tester,
    ) async {
      // The two sentences are opposite statements about which limit is now in the way,
      // and only one can be true at a time. Showing both would leave a parent working out
      // which one they are up against, which is the confusion both exist to prevent.
      budgetNote =
          'Screen time runs out before then, so the PC will still lock. Grant '
          'more minutes as well if you mean them to keep going.';

      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);
        await tester.tap(find.text('Approve'));
        await settle(tester);
        await tester.tap(find.text(laterBedtimeLabel));
        await settle(tester);
        await tester.tap(find.text('30 min'));
        await settle(tester);

        expect(
          find.textContaining('Bedtime is in force now'),
          findsNothing,
          reason: 'bedtime has moved, so that sentence has stopped being true',
        );
        expect(
          find.textContaining('Screen time runs out before then'),
          findsOneWidget,
          reason:
              'dropping this reproduces exactly the hole nestwatch wrote this '
              'field to close — a promise the system cannot keep, made silently',
        );
      });
    });

    testWidgets('and the note it answered stops being shown', (tester) async {
      // The note said bedtime would take the minutes back. Once bedtime has moved that has
      // stopped being the state of things, and leaving it up would argue with the
      // confirmation beside it.
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);
        await tester.tap(find.text('Approve'));
        await settle(tester);
        await tester.tap(find.text(laterBedtimeLabel));
        await settle(tester);
        await tester.tap(find.text('30 min'));
        await settle(tester);

        expect(find.textContaining('Bedtime is in force now'), findsNothing);

        // What the parent is *told* is asserted by `bedtimeConfirmation` above rather than
        // here, and the reason is worth recording. This screen has already shown one snack
        // bar — "Approved — 30 more minutes today." — and `ScaffoldMessenger` shows one at
        // a time, so the confirmation for this action is queued rather than built. Waiting
        // it out does not work either: inside `runAsync` the snack bar's timer is a *real*
        // timer, so `pump(Duration)` advances the test clock past it without retiring it,
        // and only four real seconds would. Four seconds of wall time to observe a string
        // is a bad trade when the string is a pure function of the payload.
      });
    });
  });
}

/// Minimal JSON string encoder, so the fixture above can be embedded verbatim without
/// pulling `dart:convert` in for one call.
String _json(String s) => '"${s.replaceAll('"', r'\"')}"';
