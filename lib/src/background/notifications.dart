/// Telling a parent that a request is waiting.
///
/// One channel, one notification id per request. Android replaces a notification when a
/// second arrives with the same id, so re-posting the same request cannot stack — but
/// [SeenRequestStore] stops it being re-posted at all, because a notification that
/// reappears every fifteen minutes teaches a parent to dismiss it unread.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/models.dart';
import 'notification_actions.dart';

const _channelId = 'nestwatch.time_requests';
const _channelName = 'Time requests';
const _channelDescription =
    'Tells you when your child asks for more screen time.';

/// A **second channel**, so that muting one does not mute the other.
///
/// Android lets a parent turn off a channel without turning off the app. Someone who
/// silences *Time requests* — reasonably, during a work day — must still be reachable
/// when this phone stops being able to see them at all, because that notice is the only
/// thing standing between them and a silence they would read as "no requests".
const _signInChannelId = 'nestwatch.sign_in';
const _signInChannelName = 'Sign-in';
const _signInChannelDescription =
    'Tells you when this phone needs you to sign in to your PC again.';

/// The id [notifySignInNeeded] posts under.
///
/// **Negative on purpose.** Every other notification here is posted under
/// `request.id.hashCode`, and a fixed positive constant could in principle be some
/// request id's hash — in which case a lapsed session would silently replace a pending
/// request, or the reverse. `String.hashCode` on this VM is never negative (checked over
/// 400k random strings and over the shapes a real request id takes; the lowest seen was
/// 1), so a negative id cannot collide with one. `test/notifications_id_test.dart`
/// holds that property, because it is an assumption about someone else's hash function.
const int signInNoticeId = -1;

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

/// Prepare the plugin. Safe to call in either isolate, and cheap enough to call again.
Future<void> initNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');

  // **Darwin settings are not optional.** Without them `initialize` throws "iOS settings
  // must be set when targeting iOS" — before `runApp`, out of `main`, so the app is a
  // blank white screen with the failure only in the device log. It built, the pin proof
  // passed, and the app was dead on arrival; the integration test never calls `main`, so
  // nothing here noticed. Found by running it and looking at the screen.
  //
  // Permissions are NOT requested at startup. iOS shows the prompt the moment they are,
  // and a parent who has just opened an app they have not paired yet is being asked about
  // something that cannot happen. `requestNotificationPermission` asks later, when the
  // parent turns notifications on — which is also what the Android tier does.
  final darwin = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestSoundPermission: false,
    requestBadgePermission: false,
    // iOS attaches buttons to a *category* declared up front, not to each notification
    // the way Android does. The identifier here is what `notifyTimeRequests` names.
    notificationCategories: <DarwinNotificationCategory>[
      DarwinNotificationCategory(
        timeRequestCategoryId,
        actions: <DarwinNotificationAction>[
          DarwinNotificationAction.plain(approveActionId, 'Approve'),
          DarwinNotificationAction.plain(denyActionId, 'Deny'),
        ],
      ),
    ],
  );

  // 22.x takes `settings:` by name; the old positional form no longer compiles.
  await _plugin.initialize(
    settings: InitializationSettings(android: android, iOS: darwin),
    // Both isolates: a tap while the app is dead lands in the background one.
    onDidReceiveNotificationResponse: onNotificationAction,
    onDidReceiveBackgroundNotificationResponse: onNotificationAction,
  );
}

/// The iOS category that carries Approve and Deny. Declared once at initialize time.
const String timeRequestCategoryId = 'nestwatch.time_request';

/// Ask for POST_NOTIFICATIONS (Android 13+).
///
/// Only meaningful from the UI isolate, and only after a frame — a permission dialog
/// needs an Activity. Returns whether notifications may be posted.
Future<bool> requestNotificationPermission() async {
  final android = _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  if (android == null) return false;
  final granted = await android.requestNotificationsPermission();
  return granted ?? false;
}

Future<bool> notificationsEnabled() async {
  final android = _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  return await android?.areNotificationsEnabled() ?? false;
}

/// What every time-request notification is posted with.
///
/// Top-level rather than a local inside [notifyTimeRequests] so a plain test can hold the
/// real object. The alternative was reading this file's text for the word `onlyAlertOnce`,
/// which proves that a string is present rather than that a notification carries a flag —
/// a distinction `docs/OPEN-FINDINGS.md` M18 records this repo getting wrong once, in a
/// scanner that could not match its own needle. Source-scraping is right for the manifest
/// and the `Info.plist`, where there is no runtime handle at all. Here there is one.
const NotificationDetails timeRequestDetails = NotificationDetails(
  iOS: DarwinNotificationDetails(categoryIdentifier: timeRequestCategoryId),
  android: AndroidNotificationDetails(
    _channelId,
    _channelName,
    channelDescription: _channelDescription,
    importance: Importance.high,
    priority: Priority.high,
    // The parent acts in the app; the notification is the prompt, not the record.
    autoCancel: true,
    // A re-post of a request already on screen updates in silence.
    //
    // Two paths reach one, and both were already known and priced. `pollOnce`
    // announces before it records, so a round that dies in between announces again —
    // its comment calls that "one re-alert on a single notification" and accepts it,
    // correctly, as the cheaper half of an at-least-once trade. And WorkManager may
    // re-run a task on its own account.
    //
    // What made it worth closing is a third path that is not a rare crash: the
    // fifteen-minute tier and the opt-in "watch now" service poll the same PC from two
    // isolates against one `SecureSeenRequestStore`, with no lock between load and
    // save. Interleaved, both can see the same request as fresh. The dedup that makes
    // that harmless is the shared id — Android replaces rather than stacks — and this
    // is what stops the replacement buzzing a second time.
    //
    // It does NOT suppress an alert for a notification the parent has dismissed:
    // Android only skips the sound when the notification is already showing, which is
    // precisely the case where they have been told. See the register entry on why the
    // two tiers are not made mutually exclusive instead.
    onlyAlertOnce: true,
    // Answer without opening anything. The work happens in a background isolate that
    // installs the pin for itself — see notification_actions.dart, including why every
    // path that does not end in the change being made says so out loud.
    actions: <AndroidNotificationAction>[
      AndroidNotificationAction(approveActionId, 'Approve'),
      AndroidNotificationAction(denyActionId, 'Deny'),
    ],
  ),
);

/// Post one notification per newly-seen request.
Future<void> notifyTimeRequests(List<TimeRequest> requests) async {
  if (requests.isEmpty) return;
  await initNotifications();

  for (final request in requests) {
    await _plugin.show(
      // Stable per request, so a re-post replaces rather than stacks.
      id: request.id.hashCode,
      // The id travels to the action handler and back; it is how an isolate with no
      // memory of this loop knows which request a button belonged to.
      payload: request.id,
      title: '${request.minutes} more minutes?',
      body: request.reason.isEmpty
          ? 'Your child asked for more screen time.'
          : request.reason,
      notificationDetails: timeRequestDetails,
    );
  }
}

/// Clear a notification once its request is no longer pending — resolved here, in the
/// browser dashboard, or on another phone.
Future<void> cancelForRequest(String id) => _plugin.cancel(id: id.hashCode);

/// Tell the parent something about an answer they gave from the notification.
///
/// Deliberately a separate id from the request's own, so it cannot replace a still-live
/// prompt for a different request — and deliberately not `autoCancel: false`, because a
/// parent who reads it and swipes it away has understood it.
///
/// [title] is a parameter rather than the constant it used to be because there are now
/// two things worth saying here, and they are not both bad news. One is that the answer
/// did not land. The other is that it did, and bedtime will swallow it anyway — which
/// under the old fixed title *"That did not go through"* would have been a false
/// statement about a grant that went through perfectly. One request produces at most one
/// of the two, so they share an id and the second cannot pile up behind the first.
Future<void> notifyAboutAnswer(
  String requestId, {
  required String title,
  required String message,
}) async {
  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    ),
  );
  await _plugin.show(
    id: 'answer:$requestId'.hashCode,
    title: title,
    body: message,
    notificationDetails: details,
  );
}

/// Tell the parent this phone can no longer reach their PC on their behalf.
///
/// Posted by the background poll when a round comes back `sessionExpired`, and **only**
/// through [SignInNoticeStore], which is what stops it being posted every fifteen
/// minutes. See `poll_logic.dart` for why that case is separated from the ordinary
/// away-from-home failure, which stays silent.
///
/// ## What it says, and what it carefully does not
///
/// It does not say "expired". Since nestwatch 0.7.0 a 401 has four causes — the sliding
/// idle window, the new absolute one-month cap, a session revoked from the parent's
/// *Signed-in devices* card, and a pre-0.7.0 session refused for carrying no scope — and
/// they are indistinguishable on the wire, all four arriving as a bare 401. "Expired" is
/// false for the revoked one, and a parent who has just signed this phone out from their
/// dashboard being told its sign-in "expired" is being told something they know is wrong.
/// *Ended* is true of all four, and the remedy is the same for all four.
///
/// It leads with the consequence rather than the cause, because the consequence is the
/// part a parent cannot see for themselves: notifications stopping looks exactly like
/// nobody asking.
///
/// No action buttons. A body tap opens the app, which is where the password is typed —
/// and `onNotificationAction` ignores everything that is not an action tap, so this
/// cannot be misread as answering a request.
const NotificationDetails signInNoticeDetails = NotificationDetails(
  iOS: DarwinNotificationDetails(),
  android: AndroidNotificationDetails(
    _signInChannelId,
    _signInChannelName,
    channelDescription: _signInChannelDescription,
    importance: Importance.high,
    priority: Priority.high,
    // Dismissable: a parent who has seen it and cannot act right now should be able
    // to clear it. The store, not the notification, is what remembers — and since the
    // store began keeping a *time* rather than a bit, remembering no longer means
    // forever. See `sign_in_notice.dart`.
    autoCancel: true,
    // Belt and braces with [SignInNoticeStore]. If a re-post ever does happen —
    // a store that failed to write, a reinstall, the once-a-day repeat landing on a
    // notice still on screen — it updates in place in silence rather than sounding again.
    onlyAlertOnce: true,
  ),
);

Future<void> notifySignInNeeded() async {
  await initNotifications();
  await _plugin.show(
    id: signInNoticeId,
    // No payload: there is no request this belongs to, and `_handleAndReport` would
    // take a non-null one as an id to answer.
    title: 'Sign in to nestwatch again',
    body:
        'This phone\'s sign-in has ended, so it can no longer tell you when your '
        'child asks for more screen time. Open nestwatch to sign in.',
    notificationDetails: signInNoticeDetails,
  );
}

/// Take it down. Called when a poll succeeds again, so the notice does not outlive the
/// problem it describes.
Future<void> cancelSignInNeeded() => _plugin.cancel(id: signInNoticeId);
