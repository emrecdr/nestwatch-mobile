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

/// Post one notification per newly-seen request.
Future<void> notifyTimeRequests(List<TimeRequest> requests) async {
  if (requests.isEmpty) return;
  await initNotifications();

  const details = NotificationDetails(
    iOS: DarwinNotificationDetails(categoryIdentifier: timeRequestCategoryId),
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      // The parent acts in the app; the notification is the prompt, not the record.
      autoCancel: true,
      // Answer without opening anything. The work happens in a background isolate that
      // installs the pin for itself — see notification_actions.dart, including why every
      // path that does not end in the change being made says so out loud.
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(approveActionId, 'Approve'),
        AndroidNotificationAction(denyActionId, 'Deny'),
      ],
    ),
  );

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
      notificationDetails: details,
    );
  }
}

/// Clear a notification once its request is no longer pending — resolved here, in the
/// browser dashboard, or on another phone.
Future<void> cancelForRequest(String id) => _plugin.cancel(id: id.hashCode);

/// Tell the parent an answer they gave from the notification did not land.
///
/// Deliberately a separate id from the request's own, so it cannot replace a still-live
/// prompt for a different request — and deliberately not `autoCancel: false`, because a
/// parent who reads it and swipes it away has understood it.
Future<void> notifyActionFailed(String requestId, String message) async {
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
    id: 'failed:$requestId'.hashCode,
    title: 'That did not go through',
    body: message,
    notificationDetails: details,
  );
}
