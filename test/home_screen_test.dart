/// The frame every other screen sits inside, which nothing had ever drawn.
///
/// `home_screen.dart` is the largest un-rendered file in `lib/src/ui/` and the only one
/// left that needs no platform channel. `M19` recorded it as needing "a live
/// NestwatchClient and opens an event stream on init", which is true and, as with the five
/// screens before it, turned out not to be a barrier: a TLS stub on loopback answers both.
///
/// ## The event stream is absent here, and that is a state rather than a shortcut
///
/// `/api/events` answers **404**, which is a PC too old to have the endpoint — a case
/// `server_events.dart` handles deliberately and describes at length: it is "a PC this app
/// works against on every other route", the 60 s poll underneath is the backstop, and
/// signing a parent out over it "took away an app that was working". So this exercises the
/// permanent-failure branch of `ServerEvents.onError` rather than skipping the stream.
///
/// **A live stream is not covered, and the reason is the rig rather than the app.** With
/// the connection open, `tearDown`'s `NestwatchClient.close()` destroys an in-flight read
/// and Dart reports `Connection closed while receiving data` *after the test has
/// completed*, where nothing can catch it — and `flutter_test` then cannot even print it,
/// because demangling a `package:stack_trace` chain trips an assertion in
/// `StackFrame.fromStackTraceLine`. Setting `FlutterError.demangleStackTrace` to the
/// identity is what made the real message visible; it is not a fix.
///
/// Five shapes were tried and none contained it: a bare open response, a well-formed
/// keepalive, disposing the widget first so `_events.stop()` cancels the subscription,
/// closing the client inside the test, and taking the exception explicitly. Cancelling a
/// subscription does not close the socket — the connection returns to the pool — so the
/// destroy always outlives the scope that could handle it.
///
/// Worth someone's attention, and deliberately *not* claimed as an app defect here:
/// whether `NestwatchClient.close()` can meet a live events stream in the running app is a
/// separate question, and the ordering in `_clientFor` and `HomeScreen.dispose` suggests it
/// may not. What is established is that this harness cannot hold an open one.
///
/// ## What one pump covers here
///
/// The tabs are an `IndexedStack`, so **all four children are constructed on the first
/// build** — that is the whole reason it is an IndexedStack rather than a `TabBarView`, so
/// each keeps its state across a switch. Only the visible one fetches; the other three are
/// built, laid out and left alone, which is exactly the arrangement a test should hold.
///
/// ## The assertion this file exists for
///
/// `_caveats` decides which warnings band across every screen, and it is deliberately not
/// all of them: `ContractCheck.isWarning` is `serverOlder` **alone**, because a PC that is
/// merely *newer* "still works everywhere" and belongs in the identity dialog instead.
///
/// That decision was load-bearing in an argument recorded in `refusal_lines_test.dart`, and
/// checking it there is how `M33` found the argument's premise overstated. It was asserted
/// at the unit level in `server_contract_test.dart` and nowhere at the widget, so what
/// actually reaches a parent's screen was the one part nothing held. Three versions here —
/// older, agreed, newer — and the middle and last must produce no band.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/api/server_contract.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/background/sign_in_notice.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'package:nestwatch_mobile/src/ui/home_screen.dart';

import 'support/certs.dart';

const _sizes = <String, Size>{
  'small phone (320x568)': Size(320, 568),
  'large phone (430x932)': Size(430, 932),
};

String _golden(String name) => File('test/golden/$name').readAsStringSync();

void main() {
  const dir = fixtureDir;
  late HttpServer server;
  late NestwatchClient client;
  late PairingController controller;
  late ServerIdentity identity;

  setUp(() async {
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
      switch (request.uri.path) {
        // Held open and never written to, which is the healthy state for this stream —
        // a PC where nothing is happening. Closing it instead would be a disconnect, and
        // `ServerEvents` would schedule a reconnect whose timer outlives the test.
        case '/api/events':
          response.statusCode = 404;
          await response.close();
          return;
        case '/api/time-requests':
          response.write(_golden('time-requests.json'));
        case '/api/usage/today':
          response.write(_golden('usage-today.json'));
        case '/api/time-codes':
          response.write(_golden('time-codes.json'));
        default:
          response.write('{"ok":true}');
      }
      await response.close();
    });

    HttpOverrides.global = PinnedHttpOverrides(
      pin: fingerprintOf('$dir/server.cert.pem'),
    );
    client = NestwatchClient('127.0.0.1:${server.port}');
    identity = ServerIdentity(
      host: '127.0.0.1',
      port: server.port,
      fingerprint: fingerprintOf('$dir/server.cert.pem'),
      provenance: PinProvenance.verifiedFromQrCode,
      pairedAt: DateTime.utc(2026, 8, 1),
    );
    controller = PairingController(
      overrides: PinnedHttpOverrides(),
      identities: InMemoryServerIdentityStore(),
      sessions: InMemorySessionStore(),
      forgetAnnounced: InMemorySeenRequestStore().clear,
      withdrawSignInNotice: SignInNotice.recording().lower,
    );
  });

  tearDown(() async {
    controller.dispose();
    client.close();
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  Widget subject(String version) => MaterialApp(
    home: HomeScreen(
      controller: controller,
      client: client,
      identity: identity,
      session: SessionInfo(
        authenticated: true,
        version: version,
        scope: PairingScope.dashboard,
        reportsScopes: true,
      ),
    ),
  );

  Future<void> show(
    WidgetTester tester,
    String version, {
    Size size = const Size(430, 932),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(subject(version));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }

  group('the frame builds, with all four tabs constructed', () {
    for (final size in _sizes.entries) {
      testWidgets('on a ${size.key}', (tester) async {
        await tester.runAsync(() async {
          await show(tester, ContractCheck.testedAgainst, size: size.value);

          expect(
            tester.takeException(),
            isNull,
            reason: 'threw or overflowed while building',
          );
          for (final tab in ['Requests', 'Today', 'Screen', 'Codes']) {
            expect(find.text(tab), findsOneWidget, reason: 'the $tab tab');
          }
          // The visible tab is the only one that fetches, and this is its payload:
          // `time-requests.json`, vendored, first entry.
          expect(find.textContaining('finish the level'), findsWidgets);
        });
      });
    }
  });

  group('which caveats band every screen, and which do not', () {
    testWidgets('a PC older than this app gets a band', (tester) async {
      await tester.runAsync(() async {
        await show(tester, '0.6.0');
        expect(
          find.textContaining('Updating nestwatch on that PC is the fix'),
          findsWidgets,
          reason:
              'serverOlder is the one case where a screen is going to break and the '
              'parent holds the fix',
        );
      });
    });

    testWidgets('a PC this app was built against gets none', (tester) async {
      await tester.runAsync(() async {
        await show(tester, ContractCheck.testedAgainst);
        // The word appears on this screen only inside the identity dialog, which a tap
        // opens — so its absence here is the strip staying empty rather than the string
        // being unreachable.
        expect(find.textContaining('nestwatch'), findsNothing);
        expect(
          find.text('Requests'),
          findsOneWidget,
          reason:
              'the control: an absence proves nothing on a screen that rendered nothing',
        );
      });
    });

    testWidgets('and a PC newer than this app gets none either', (
      tester,
    ) async {
      // The decision M33 examines. The message exists — `ContractCheck.message` composes
      // one for `serverNewer` — and it reaches the identity dialog rather than the strip,
      // because `isWarning` is `serverOlder` alone. Asserted at the widget because that
      // is where a parent meets it, and because an argument elsewhere in this suite leans
      // on what they are shown without checking it.
      await tester.runAsync(() async {
        await show(tester, '9.9.9');
        expect(
          find.textContaining('this app that is behind'),
          findsNothing,
          reason:
              'the serverNewer message must not band a screen; it lives behind a tap',
        );
        // The control: the same run with an older version does band, so this absence is
        // a decision rather than a strip that never renders anything.
        expect(find.text('Requests'), findsOneWidget);
      });
    });
  });
}
