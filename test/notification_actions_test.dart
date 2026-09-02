/// Answering from the notification, and the case that makes it risky.
///
/// The notification is dismissed the moment an action is tapped, before any network call
/// happens. So a parent can tap Approve, watch it vanish, walk away, and be wrong. Every
/// branch below exists to decide whether they get told.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/background/notification_actions.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
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

  /// What the stand-in server says about bedtime when it grants. Null is the ordinary
  /// day; a string is what nestwatch sends when the minutes cannot beat the curfew.
  final String? curfewNote;

  _FakeClient({this.throws, this.resolves = true, this.curfewNote});

  @override
  Future<Decision> approveTimeRequest(String id) async {
    if (throws != null) throw throws!;
    approved.add(id);
    return Decision(acted: resolves, curfewNote: resolves ? curfewNote : null);
  }

  @override
  Future<Decision> denyTimeRequest(String id) async {
    if (throws != null) throw throws!;
    denied.add(id);
    return Decision(acted: resolves);
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
      final result = await performAction(
        actionId: approveActionId,
        requestId: 'req-1',
        open: () async => (identity: _identity, client: client),
      );
      expect(result.outcome, ActionOutcome.granted);
      expect(client.approved, ['req-1']);
      expect(actionFailureMessage(result.outcome), isNull);
      expect(
        client.closed,
        isTrue,
        reason: 'a background client must not linger',
      );
    });

    test('deny resolves, and says nothing', () async {
      final client = _FakeClient();
      final result = await performAction(
        actionId: denyActionId,
        requestId: 'req-2',
        open: () async => (identity: _identity, client: client),
      );
      expect(result.outcome, ActionOutcome.denied);
      expect(client.denied, ['req-2']);
      expect(actionFailureMessage(result.outcome), isNull);
    });
  });

  group('a grant that bedtime will swallow is not silence', () {
    // The whole risk of moving approval to a lock screen is a grant that looks like it
    // worked and did not. `curfew_note` is nestwatch answering exactly that question, and
    // it arrived on every approve while this app returned a bare bool and dropped the
    // body — so the one surface that most needed the caveat was the one furthest from it.
    const note =
        'Bedtime is in force now, so the PC will still shut down — screen time '
        'and bedtime are separate limits.';

    test('the note is reported, and not as a failure', () async {
      final client = _FakeClient(curfewNote: note);
      final result = await performAction(
        actionId: approveActionId,
        requestId: 'req-c1',
        open: () async => (identity: _identity, client: client),
      );
      expect(result.outcome, ActionOutcome.granted);
      expect(result.curfewNote, note);

      final report = answerReport(result);
      expect(report, isNotNull);
      expect(
        report!.message,
        note,
        reason:
            'passed through verbatim — that PC owns this verdict, not this phone',
      );
      expect(
        report.title,
        isNot(contains('did not go through')),
        reason: 'the minutes really were granted; only bedtime is in the way',
      );
    });

    test('an ordinary grant still says nothing at all', () async {
      // The control. Without it this group would pass just as well against code that
      // notified on every approve, which would put a notification in front of a parent
      // every time they answered their child.
      final result = await performAction(
        actionId: approveActionId,
        requestId: 'req-c2',
        open: () async => (identity: _identity, client: _FakeClient()),
      );
      expect(result.outcome, ActionOutcome.granted);
      expect(result.curfewNote, isNull);
      expect(answerReport(result), isNull);
    });

    test('a deny carries no note even when one is configured', () async {
      // Denying grants nothing, so there is nothing for bedtime to swallow. Measured
      // against 0.5.1: deny answers a bare `{"ok":true}`.
      final result = await performAction(
        actionId: denyActionId,
        requestId: 'req-c3',
        open: () async =>
            (identity: _identity, client: _FakeClient(curfewNote: note)),
      );
      expect(result.outcome, ActionOutcome.denied);
      expect(result.curfewNote, isNull);
      expect(answerReport(result), isNull);
    });
  });

  group('a failed answer leaves the request askable again', () {
    // pollOnce announces only ids missing from the seen set, and a still-pending request
    // stays in it — so without this the parent is told once that their answer failed and
    // then never prompted about that child again.
    test('a failure forgets the id, so the next poll offers it', () async {
      final seen = InMemorySeenRequestStore()..save({'req-a', 'req-b'});
      await performAction(
        actionId: approveActionId,
        requestId: 'req-a',
        open: () async => (
          identity: _identity,
          client: _FakeClient(
            throws: const NestwatchException(
              NestwatchFailure.unreachable,
              'away',
            ),
          ),
        ),
        seen: seen,
      );
      expect(await seen.load(), {'req-b'});
    });

    test('a success leaves the seen set alone', () async {
      // The poll prunes it when the request leaves the queue; nothing to do here.
      final seen = InMemorySeenRequestStore()..save({'req-a'});
      await performAction(
        actionId: approveActionId,
        requestId: 'req-a',
        open: () async => (identity: _identity, client: _FakeClient()),
        seen: seen,
      );
      expect(await seen.load(), {'req-a'});
    });

    test('an already-resolved race leaves it alone too', () async {
      final seen = InMemorySeenRequestStore()..save({'req-a'});
      await performAction(
        actionId: approveActionId,
        requestId: 'req-a',
        open: () async =>
            (identity: _identity, client: _FakeClient(resolves: false)),
        seen: seen,
      );
      expect(await seen.load(), {
        'req-a',
      }, reason: 'it is resolved; do not re-ask');
    });
  });

  group('the parent must be told when nothing happened', () {
    test(
      'an unreachable PC complains, because the notification is already gone',
      () async {
        final client = _FakeClient(
          throws: const NestwatchException(
            NestwatchFailure.unreachable,
            'not on that network',
          ),
        );
        final result = await performAction(
          actionId: approveActionId,
          requestId: 'req-3',
          open: () async => (identity: _identity, client: client),
        );
        expect(result.outcome, ActionOutcome.failed);
        final said = actionFailureMessage(result.outcome);
        expect(said, isNotNull);
        expect(said, contains('nothing changed on that PC'));
        expect(client.closed, isTrue);
      },
    );

    test('a lapsed session complains, and names the fix', () async {
      final result = await performAction(
        actionId: approveActionId,
        requestId: 'req-4',
        open: () async => null,
      );
      expect(result.outcome, ActionOutcome.notPaired);
      expect(actionFailureMessage(result.outcome), contains('sign in'));
    });
  });

  test('already resolved is silence, not a complaint', () async {
    // Two taps on a lock screen are easier than two taps on a button, and the request is
    // resolved either way — which is what the parent wanted. Explaining a race they never
    // saw would be noise.
    // The real client returns false here; it does not throw. Getting this wrong in the
    // first draft would have reported every race as a hard failure.
    final client = _FakeClient(resolves: false);
    final result = await performAction(
      actionId: approveActionId,
      requestId: 'req-5',
      open: () async => (identity: _identity, client: client),
    );
    expect(result.outcome, ActionOutcome.alreadyResolved);
    expect(actionFailureMessage(result.outcome), isNull);
  });

  group('nothing acts on a malformed tap', () {
    test('an unknown action id does nothing', () async {
      final client = _FakeClient();
      final result = await performAction(
        actionId: 'nestwatch.something-else',
        requestId: 'req-6',
        open: () async => (identity: _identity, client: client),
      );
      expect(result.outcome, ActionOutcome.failed);
      expect(client.approved, isEmpty);
      expect(client.denied, isEmpty);
    });

    test('a missing request id does nothing', () async {
      final client = _FakeClient();
      for (final id in <String?>[null, '']) {
        final result = await performAction(
          actionId: approveActionId,
          requestId: id,
          open: () async => (identity: _identity, client: client),
        );
        expect(result.outcome, ActionOutcome.failed);
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
      expect(
        opened,
        0,
        reason: 'a bad action id is rejected before opening anything',
      );
    });
  });

  group('only an action tap does anything', () {
    // The defect this group exists for: the first version acted on all three response
    // kinds, so tapping the body to open the app — or swiping the notification away —
    // posted "that did not go through" about an answer the parent never gave.
    test('an action tap is acted on', () {
      expect(
        isActionTap(NotificationResponseType.selectedNotificationAction),
        isTrue,
      );
    });

    test('tapping the body is not an answer', () {
      expect(
        isActionTap(NotificationResponseType.selectedNotification),
        isFalse,
      );
    });

    test('swiping it away is not an answer', () {
      expect(
        isActionTap(NotificationResponseType.notificationDismissed),
        isFalse,
      );
    });

    test('every response kind is decided about', () {
      // So a fourth kind added by the plugin cannot quietly start meaning "approve".
      for (final type in NotificationResponseType.values) {
        expect(
          isActionTap(type),
          type == NotificationResponseType.selectedNotificationAction,
          reason: '$type',
        );
      }
    });
  });

  test(
    'every outcome is decided about, so a new one cannot default to silence',
    () {
      for (final outcome in ActionOutcome.values) {
        // Exhaustive by construction — the switch in actionFailureMessage will not compile
        // if a case is added and not handled. This asserts the *intent*: exactly the two
        // failure outcomes speak.
        final said = actionFailureMessage(outcome);
        final shouldSpeak =
            outcome == ActionOutcome.failed ||
            outcome == ActionOutcome.notPaired;
        expect(said != null, shouldSpeak, reason: '$outcome');
      }
    },
  );
}
