/// Signed-in devices: the list, and signing one out.
///
/// ## The payloads here were captured, not composed
///
/// On 2026-09-07 a nestwatch **v0.7.0** was built out of `git archive v0.7.0` — a clean
/// published tree, not the sibling working copy — installed headlessly into a throwaway
/// data directory, and run on a loopback port. Three sessions were signed in with different
/// `User-Agent` headers and then revoked one at a time. Everything below is what came back,
/// including the failures:
///
/// * `GET /api/sessions` → the row shape asserted in `_row` below;
/// * revoking another device → `200 {"ok":true,"was_current":false}`;
/// * revoking the same handle again → `404 {"error":"no such signed-in device"}`;
/// * revoking **this** device → `200 {"ok":true,"was_current":true}`, and the next request
///   on that cookie → `401 {"error":"authentication required"}`.
///
/// `describe_session` is byte-identical between `v0.7.0` and `origin/main`, checked by diff,
/// so the released tag is what a parent's PC actually answers. nestwatch publishes no golden
/// for this endpoint — `nestwatch-mobile#M31` tracks the one it is about to publish for
/// `/session` — so these fixtures are a capture with its provenance written down rather than
/// a vendored file a checker can compare. That is weaker, and saying so is the point.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'package:nestwatch_mobile/src/ui/sessions_screen.dart';

import 'support/certs.dart';

/// One row, exactly as v0.7.0 sent it.
Map<String, Object?> _row({
  required String handle,
  required bool current,
  String? userAgent,
  String kind = 'dashboard',
  String? source,
  int? firstSeen = 1788738328,
  int lastSeen = 1788738328,
}) => {
  'handle': handle,
  'current': current,
  'expires': 1791330328,
  'first_seen': firstSeen,
  'last_seen': lastSeen,
  'scope': {'kind': kind, 'source': ?source},
  'user_agent': userAgent,
};

void main() {
  group('reading a row', () {
    test('the captured shape parses field for field', () {
      final device = SessionDevice.fromJson({
        ..._row(
          handle: '2306c57d1bac',
          current: false,
          userAgent: 'nestwatch-mobile/0.1.0 (android)',
        ),
      });

      expect(device.handle, '2306c57d1bac');
      expect(device.current, isFalse);
      expect(device.userAgent, 'nestwatch-mobile/0.1.0 (android)');
      expect(device.scopeKind, 'dashboard');
      expect(device.firstSeenEpoch, 1788738328);
      expect(device.lastSeenEpoch, 1788738328);
      expect(device.expiresEpoch, 1791330328);
    });

    test(
      'a session older than device-remembering has no name and no first use',
      () {
        final device = SessionDevice.fromJson({
          ..._row(handle: 'aaaabbbbcccc', current: false, firstSeen: null),
        });

        expect(device.userAgent, isNull, reason: 'absent must not become ""');
        expect(device.firstSeen, isNull);
      },
    );

    test('an integration row carries the name it grants time as', () {
      final device = SessionDevice.fromJson({
        ..._row(
          handle: 'ddddeeeeffff',
          current: false,
          kind: 'integration',
          source: 'studygo',
        ),
      });

      expect(device.scopeKind, 'integration');
      expect(device.scopeSource, 'studygo');
    });

    test('the handle never reaches a log line', () {
      // It addresses the row a parent is about to sign out. `TimeCode` takes the same care
      // with its own secret, for the same reason.
      final device = SessionDevice.fromJson({
        ..._row(handle: 'secret012345', current: true),
      });

      expect(device.toString(), isNot(contains('secret012345')));
    });
  });

  group('through a real request', () {
    const dir = fixtureDir;
    late HttpServer server;
    late NestwatchClient client;
    final seen = <String>[];

    /// What `/api/sessions` answers. Mutable so a test can change it between calls.
    late List<Map<String, Object?>> rows;

    /// When set, the next revoke answers 404 — a handle that matched nothing.
    var revokeMissing = false;

    /// What the next revoke reports for `was_current`.
    var revokeWasCurrent = false;

    setUp(() async {
      seen.clear();
      revokeMissing = false;
      revokeWasCurrent = false;
      rows = [
        _row(
          handle: '9d893c1bf416',
          current: true,
          userAgent: 'nestwatch-mobile/0.1.0 (android)',
        ),
        _row(
          handle: '2306c57d1bac',
          current: false,
          userAgent:
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/537.36 Chrome/141.0 Safari/537.36',
        ),
      ];

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
        final response = request.response;
        if (request.uri.path == '/api/sessions') {
          response
            ..statusCode = 200
            ..write(jsonEncode(rows));
        } else if (request.uri.path.endsWith('/revoke')) {
          if (revokeMissing) {
            response
              ..statusCode = HttpStatus.notFound
              ..write('{"error":"no such signed-in device"}');
          } else {
            response
              ..statusCode = 200
              ..write('{"ok":true,"was_current":$revokeWasCurrent}');
          }
        } else {
          response
            ..statusCode = 200
            ..write('{"ok":true}');
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

    var ended = 0;
    Widget subject() => MaterialApp(
      home: SessionsScreen(client: client, onSessionEnded: () => ended++),
    );

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    }

    testWidgets('both devices are listed, and this one is named', (
      tester,
    ) async {
      ended = 0;
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);

        expect(find.textContaining('nestwatch-mobile/0.1.0'), findsOneWidget);
        expect(find.textContaining('Chrome/141.0'), findsOneWidget);
        expect(
          find.textContaining('This phone'),
          findsOneWidget,
          reason:
              'the row whose Sign out ends this session has to be the one row a '
              'parent cannot mistake for another device',
        );
      });
    });

    testWidgets('signing out asks first, and cancelling sends nothing', (
      tester,
    ) async {
      ended = 0;
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);
        seen.clear();

        await tester.tap(find.text('Sign out').last);
        await settle(tester);
        expect(find.text('Sign that device out?'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await settle(tester);

        expect(seen, isEmpty);
      });
    });

    testWidgets('confirming revokes that handle', (tester) async {
      ended = 0;
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);
        seen.clear();

        await tester.tap(find.text('Sign out').last);
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
        await settle(tester);

        expect(seen, contains('POST /api/sessions/2306c57d1bac/revoke'));
        expect(
          ended,
          0,
          reason: 'another device ending is not this one ending',
        );
      });
    });

    testWidgets('a handle that matched nothing is not reported as a failure', (
      tester,
    ) async {
      // Measured: a second revoke of the same handle answers 404, and so does every handle
      // in a list held across a restart of that PC, because the salt is per process. Both
      // are somebody else's success, not this parent's error.
      ended = 0;
      revokeMissing = true;
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);

        await tester.tap(find.text('Sign out').last);
        await settle(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
        await settle(tester);

        expect(find.textContaining('already signed out'), findsOneWidget);
        expect(ended, 0);
      });
    });

    testWidgets('signing THIS phone out ends the session and leaves', (
      tester,
    ) async {
      // The design question, answered by measurement rather than taste. nestwatch allows
      // it on purpose, answers `was_current: true`, and the next request on that cookie is
      // a 401 — so staying here would leave a list that cannot be refreshed.
      ended = 0;
      revokeWasCurrent = true;
      await tester.runAsync(() async {
        await tester.pumpWidget(subject());
        await settle(tester);

        await tester.tap(find.text('Sign out').first);
        await settle(tester);
        expect(
          find.text('Sign this phone out?'),
          findsOneWidget,
          reason: 'the wording has to say the consequence lands here',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
        await settle(tester);

        expect(
          ended,
          1,
          reason:
              'the cookie is already dead; this has to hand back the same way a '
              'lapsed sign-in does rather than stay on a dead screen',
        );
      });
    });
  });
}
