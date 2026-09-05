/// Pressing Lock, and — the part that matters — not pressing it.
///
/// ## Why this is a widget test and not a wire test
///
/// `api_wire_test.dart` already proves what `NestwatchClient.lockScreen` puts on the
/// wire. What it cannot reach is the decision in front of it: locking has **no undo on
/// this side**. nestwatch publishes no "unlock", and that is deliberate rather than an
/// omission — a machine is unlocked by the person sitting at it, with their own password.
/// So the confirmation dialog is the only thing between a mis-tap and a child's screen
/// going away, and a claim that important should not rest on reading the code.
///
/// `screen_render_test.dart` cannot host this. It skips every screen that needs a
/// `NestwatchClient`, and says so in its own coverage list — this screen is named there as
/// "needs a NestwatchClient; the body is JPEG bytes off the PC".
///
/// ## Why everything runs inside `runAsync`
///
/// `testWidgets` drives a fake clock, and a fake clock does not move real sockets. The
/// request here goes over an actual TLS connection to an actual server on loopback, for
/// the same reason the rest of this suite prefers that to a mock: the assertion is about
/// what the server *received*, which a stubbed client cannot be wrong about and therefore
/// cannot be right about either.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'package:nestwatch_mobile/src/ui/screenshot_screen.dart';

import 'support/certs.dart';

void main() {
  const dir = fixtureDir;
  late HttpServer server;
  late NestwatchClient client;

  /// Every path the server was asked for, with its method.
  final seen = <String>[];

  setUp(() async {
    seen.clear();
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
      request.response
        ..statusCode = 200
        ..write('{"ok":true}');
      await request.response.close();
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

  /// The screen, alone, with live view off — which is how it always starts.
  Widget subject() => MaterialApp(
    home: Scaffold(
      body: ScreenshotScreen(
        client: client,
        visible: true,
        // A lapsed session is handled a level up, and no test here provokes one.
        onFailure: (_) {},
      ),
    ),
  );

  /// Let the real socket finish, then rebuild. A fixed pause rather than a poll because
  /// the server is in this process on loopback and answers immediately; if this ever goes
  /// flaky the honest fix is to wait on the request rather than to lengthen the sleep.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }

  testWidgets('the control is there, and asks before it acts', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(subject());
      await tester.pump();

      expect(find.text('Lock this screen'), findsOneWidget);
      expect(
        seen,
        isEmpty,
        reason: 'rendering the screen must not talk to that PC',
      );

      await tester.tap(find.text('Lock this screen'));
      await tester.pump();

      expect(find.text('Lock this screen?'), findsOneWidget);
      expect(
        seen,
        isEmpty,
        reason: 'opening the dialog is not the act; confirming it is',
      );
    });
  });

  testWidgets('cancelling sends nothing at all', (tester) async {
    // The mutation this exists to kill acts on a cancelled dialog. There is no way back
    // from a lock on this side, so a tap the parent explicitly withdrew must not reach
    // that PC.
    await tester.runAsync(() async {
      await tester.pumpWidget(subject());
      await tester.pump();

      await tester.tap(find.text('Lock this screen'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.text('Lock this screen?'), findsNothing);
      expect(seen, isEmpty);
    });
  });

  testWidgets('confirming sends exactly one POST to /api/lock', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(subject());
      await tester.pump();

      await tester.tap(find.text('Lock this screen'));
      await tester.pump();
      // The dialog's confirm button, not the outlined control behind it — they read
      // differently on purpose so this finder cannot pick the wrong one.
      await tester.tap(find.widgetWithText(FilledButton, 'Lock screen'));
      await settle(tester);

      expect(seen, ['POST /api/lock']);
    });
  });

  testWidgets('and says so, in words about the child rather than the call', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(subject());
      await tester.pump();

      await tester.tap(find.text('Lock this screen'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Lock screen'));
      await settle(tester);

      expect(
        find.textContaining('their own password'),
        findsOneWidget,
        reason:
            'the confirmation this screen gives has to answer the question the '
            'parent actually has next, which is how their child gets back in',
      );
    });
  });
}
