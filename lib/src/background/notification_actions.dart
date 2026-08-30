/// Answering a request from the notification, without opening the app.
///
/// ## Why this is worth a file
///
/// The loop this whole app exists for is: a child asks, a phone buzzes, a parent says yes
/// or no. Before this, answering meant unlock, find the app, find the tab, find the row,
/// press — six steps to answer a yes/no question the notification had already stated in
/// full.
///
/// The expensive half was already built. [openBackgroundSession] returns a pinned,
/// signed-in client inside a background isolate; it is how the fifteen-minute poll works.
/// This is that, reached from a button on a lock screen.
///
/// ## The part that needs care
///
/// `AndroidNotificationAction` dismisses the notification when it is tapped
/// (`cancelNotification` defaults true), and the work happens afterwards, in an isolate,
/// over a network that may not be there. So the notification can vanish and the grant can
/// fail — and a parent who tapped Approve, watched it disappear, and walked away would
/// have every reason to believe their child had the minutes.
///
/// **That silent gap is the whole risk of moving this to a lock screen**, so every path
/// that does not end in the change being made posts a second notification saying so. It
/// is the same rule the rest of this codebase keeps arriving at: a thing that stops
/// working must not look like a thing that worked.
library;

import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/nestwatch_api.dart';
import 'background_session.dart';
import 'notifications.dart';

/// Action ids, which travel to Android and back as strings.
const String approveActionId = 'nestwatch.approve';
const String denyActionId = 'nestwatch.deny';

/// What a tapped action did, so a caller can be tested without a notification.
enum ActionOutcome {
  granted,
  denied,

  /// The request was resolved elsewhere first — in the browser, on another phone, or by
  /// the parent tapping twice. Not a failure: the queue simply moved on.
  alreadyResolved,

  /// Nothing was paired or signed in. Nothing to do and nothing to say.
  notPaired,

  /// It could not be done. The parent must be told, because the notification is gone.
  failed,
}

/// Carry out a tapped action. Pure of plugin calls so it can be driven in a test.
Future<ActionOutcome> performAction({
  required String? actionId,
  required String? requestId,
  Future<BackgroundSession?> Function() open = openBackgroundSession,
}) async {
  if (requestId == null || requestId.isEmpty) return ActionOutcome.failed;
  if (actionId != approveActionId && actionId != denyActionId) {
    return ActionOutcome.failed;
  }

  final session = await open();
  if (session == null) return ActionOutcome.notPaired;

  try {
    // Both return **false** rather than throwing when the request was already resolved:
    // nestwatch answers 400 under its mutex, and `_resolveTimeRequest` turns that into a
    // value before `_requireOk` ever sees it. Checked in the client rather than assumed —
    // a first draft of this file caught a `NestwatchFailure.alreadyResolved` that these
    // two calls cannot raise, which would have reported every race as a hard failure and
    // told the parent nothing happened when something had.
    //
    // The race matters more here than in the app: two taps on a lock screen are easier
    // than two on a button, and the browser or another phone may have answered already.
    final resolved = actionId == approveActionId
        ? await session.client.approveTimeRequest(requestId)
        : await session.client.denyTimeRequest(requestId);
    if (!resolved) return ActionOutcome.alreadyResolved;
    return actionId == approveActionId
        ? ActionOutcome.granted
        : ActionOutcome.denied;
  } on NestwatchException {
    // Unreachable, lapsed, refused — anything that means the change was not made.
    return ActionOutcome.failed;
  } finally {
    session.client.close();
  }
}

/// The entry point Android calls in its own isolate.
///
/// `vm:entry-point` keeps it from being tree-shaken: nothing in Dart references it, so
/// without the annotation a release build would drop the function Android is holding a
/// handle to — and the failure would be a button that does nothing, silently.
@pragma('vm:entry-point')
void onNotificationAction(NotificationResponse response) {
  unawaited(
    _handleAndReport(actionId: response.actionId, requestId: response.payload),
  );
}

Future<void> _handleAndReport({
  required String? actionId,
  required String? requestId,
}) async {
  await initNotifications();
  final outcome = await performAction(actionId: actionId, requestId: requestId);
  final complaint = actionFailureMessage(outcome);
  if (complaint != null) {
    await notifyActionFailed(requestId ?? '', complaint);
  }
}

/// What to tell the parent, or null when the notification vanishing was the truth.
///
/// [ActionOutcome.alreadyResolved] says nothing on purpose: the request *is* resolved,
/// which is what the parent wanted, and explaining a race they never saw would be noise.
String? actionFailureMessage(ActionOutcome outcome) => switch (outcome) {
  ActionOutcome.granted || ActionOutcome.denied => null,
  ActionOutcome.alreadyResolved => null,
  ActionOutcome.notPaired =>
    'That answer did not go through — this phone is no longer signed in to that PC. '
        'Open Nestwatch to sign in again.',
  ActionOutcome.failed =>
    'That answer did not go through, so nothing changed on that PC. If you are away '
        'from home Nestwatch cannot reach it — open the app while on your home Wi-Fi '
        'and answer there.',
};
