/// Answering from the notification, and the case that makes it risky.
///
/// The notification is dismissed the moment an action is tapped, before any network call
/// happens. So a parent can tap Approve, watch it vanish, walk away, and be wrong. Every
/// branch below exists to decide whether they get told.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/background/notification_actions.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';

class _FakeClient implements NestwatchClient {
  final NestwatchException? throws;

  /// What the real client returns: false when the server answered 400 because the
  /// request was already resolved elsewhere.
  final bool resolves;
  final List<String> approved = [];
  final List<String> denied = [];
  bool closed = false;

  _FakeClient({this.throws, this.resolves = true});

  @override
  Future<bool> approveTimeRequest(String id) async {
    if (throws != null) throw throws!;
    approved.add(id);
    return resolves;
  }

  @override
  Future<bool> denyTimeRequest(String id) async {
    if (throws != null) throw throws!;
    denied.add(id);
    return resolves;
  }

  @override
  void close() => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A stand-in identity. `performAction` reads only the client off the session, but the
/// record carries both, so this exists to make one that is real rather than thrown.
final _identity = ServerIdentity(
  host: '192.168.1.42',
  port: 8443,
  fingerprint: Fingerprint.fromBytes(List<int>.filled(32, 7)),
  provenance: PinProvenance.verifiedFromQrCode,
  pairedAt: DateTime(2026, 8, 30),
);

void main() {

  group('the happy paths', () {
    test('approve grants, and says nothing', () async {
      final client = _FakeClient();
      final outcome = await performAction(
        actionId: approveActionId,
        requestId: 'req-1',
        open: () async => (identity: _identity, client: client),
      );
      expect(outcome, ActionOutcome.granted);
      expect(client.approved, ['req-1']);
      expect(actionFailureMessage(outcome), isNull);
      expect(client.closed, isTrue, reason: 'a background client must not linger');
    });

    test('deny resolves, and says nothing', () async {
      final client = _FakeClient();
      final outcome = await performAction(
        actionId: denyActionId,
        requestId: 'req-2',
        open: () async => (identity: _identity, client: client),
      );
      expect(outcome, ActionOutcome.denied);
      expect(client.denied, ['req-2']);
      expect(actionFailureMessage(outcome), isNull);
    });
  });

  group('the parent must be told when nothing happened', () {
    test('an unreachable PC complains, because the notification is already gone', () async {
      final client = _FakeClient(
        throws: const NestwatchException(
          NestwatchFailure.unreachable,
          'not on that network',
        ),
      );
      final outcome = await performAction(
        actionId: approveActionId,
        requestId: 'req-3',
        open: () async => (identity: _identity, client: client),
      );
      expect(outcome, ActionOutcome.failed);
      final said = actionFailureMessage(outcome);
      expect(said, isNotNull);
      expect(said, contains('nothing changed on that PC'));
      expect(client.closed, isTrue);
    });

    test('a lapsed session complains, and names the fix', () async {
      final outcome = await performAction(
        actionId: approveActionId,
        requestId: 'req-4',
        open: () async => null,
      );
      expect(outcome, ActionOutcome.notPaired);
      expect(actionFailureMessage(outcome), contains('sign in'));
    });
  });

  test('already resolved is silence, not a complaint', () async {
    // Two taps on a lock screen are easier than two taps on a button, and the request is
    // resolved either way — which is what the parent wanted. Explaining a race they never
    // saw would be noise.
    // The real client returns false here; it does not throw. Getting this wrong in the
    // first draft would have reported every race as a hard failure.
    final client = _FakeClient(resolves: false);
    final outcome = await performAction(
      actionId: approveActionId,
      requestId: 'req-5',
      open: () async => (identity: _identity, client: client),
    );
    expect(outcome, ActionOutcome.alreadyResolved);
    expect(actionFailureMessage(outcome), isNull);
  });

  group('nothing acts on a malformed tap', () {
    test('an unknown action id does nothing', () async {
      final client = _FakeClient();
      final outcome = await performAction(
        actionId: 'nestwatch.something-else',
        requestId: 'req-6',
        open: () async => (identity: _identity, client: client),
      );
      expect(outcome, ActionOutcome.failed);
      expect(client.approved, isEmpty);
      expect(client.denied, isEmpty);
    });

    test('a missing request id does nothing', () async {
      final client = _FakeClient();
      for (final id in <String?>[null, '']) {
        final outcome = await performAction(
          actionId: approveActionId,
          requestId: id,
          open: () async => (identity: _identity, client: client),
        );
        expect(outcome, ActionOutcome.failed);
      }
      expect(client.approved, isEmpty);
    });

    test('a tap with no session open is never attempted', () async {
      // performAction must not reach for a client before it has one.
      var opened = 0;
      await performAction(
        actionId: 'bogus',
        requestId: 'req-7',
        open: () async {
          opened++;
          return null;
        },
      );
      expect(opened, 0, reason: 'a bad action id is rejected before opening anything');
    });
  });

  test('every outcome is decided about, so a new one cannot default to silence', () {
    for (final outcome in ActionOutcome.values) {
      // Exhaustive by construction — the switch in actionFailureMessage will not compile
      // if a case is added and not handled. This asserts the *intent*: exactly the two
      // failure outcomes speak.
      final said = actionFailureMessage(outcome);
      final shouldSpeak =
          outcome == ActionOutcome.failed || outcome == ActionOutcome.notPaired;
      expect(said != null, shouldSpeak, reason: '$outcome');
    }
  });
}
