/// A notification that replaces another must not sound a second time.
///
/// ## Why this is a property of the set, not of one notification
///
/// Everything this app posts is keyed so that a repeat *replaces* rather than stacks —
/// requests by `request.id.hashCode`, the sign-in notice by a fixed negative id. That
/// dedup is what makes the repository's at-least-once choices safe, and there are three
/// of them:
///
///   * `pollOnce` announces **before** it records, so a round that dies in between
///     announces again. Its comment prices that at "one re-alert on a single
///     notification" and takes it, correctly, over the alternative — recording first
///     loses the request silently and forever;
///   * WorkManager may re-run a task on its own account, and documents that it may;
///   * the fifteen-minute tier and the opt-in "watch now" service poll the same PC from
///     two isolates against one `SecureSeenRequestStore`, with nothing locking the gap
///     between its load and its save. Interleaved, both rounds can see the same request
///     as fresh.
///
/// So a replacement is not an edge case here; it is designed for. `onlyAlertOnce` is what
/// makes the replacement cost nothing, and it has to hold for **every** alerting
/// notification rather than for whichever one somebody remembered — which is why this
/// asserts over a list that a new channel has to be added to.
///
/// It does not suppress an alert the parent should get: Android skips the sound only when
/// the notification is already showing, and a notification already showing is one they
/// have already been told about.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/background/notifications.dart';

void main() {
  /// Every set of details this app posts an *alert* with.
  ///
  /// `notifyAboutAnswer` is deliberately absent: it reports on an answer the parent gave
  /// and is posted once per request under its own id, so it has nothing to replace. The
  /// watch service's persistent notification is absent for the opposite reason — it is a
  /// status line at LOW importance that never alerts at all, and it belongs to
  /// `flutter_foreground_task` rather than to this file.
  const alerting = <String, NotificationDetails>{
    'time requests': timeRequestDetails,
    'the sign-in notice': signInNoticeDetails,
  };

  test('the list is not empty, so what follows is not vacuous', () {
    // The control. A `for` over nothing passes every assertion inside it.
    expect(alerting, isNotEmpty);
  });

  group('every alerting notification updates in silence', () {
    for (final entry in alerting.entries) {
      test(entry.key, () {
        final android = entry.value.android;
        expect(
          android,
          isNotNull,
          reason:
              'Android is the platform with a background tier; details without an '
              'android half post nothing there',
        );
        expect(
          android!.onlyAlertOnce,
          isTrue,
          reason:
              'this notification is re-posted under an id it shares with itself, by '
              'at least three paths this repo has documented and accepted. Without '
              'this, each of them buzzes a parent a second time about a request they '
              'have already been shown.',
        );
      });
    }
  });

  test('and still alerts the first time, which is the whole point', () {
    // `onlyAlertOnce` suppresses the sound only for a notification already on screen, so
    // importance and priority are what decide whether the first one is heard at all.
    // Lowering either would make the flag above look like the cause of a silent phone.
    for (final entry in alerting.entries) {
      expect(
        entry.value.android!.importance,
        Importance.high,
        reason: '${entry.key} has to be heard the first time',
      );
    }
  });
}
