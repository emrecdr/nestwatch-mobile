/// Telling a parent that a request is waiting.
///
/// One channel, one notification id per request. Android replaces a notification when a
/// second arrives with the same id, so re-posting the same request cannot stack — but
/// [SeenRequestStore] stops it being re-posted at all, because a notification that
/// reappears every fifteen minutes teaches a parent to dismiss it unread.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/models.dart';

const _channelId = 'nestwatch.time_requests';
const _channelName = 'Time requests';
const _channelDescription =
    'Tells you when your child asks for more screen time.';

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

/// Prepare the plugin. Safe to call in either isolate, and cheap enough to call again.
Future<void> initNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  // 22.x takes `settings:` by name; the old positional form no longer compiles.
  await _plugin.initialize(
    settings: const InitializationSettings(android: android),
  );
}

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
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      // The parent acts in the app; the notification is the prompt, not the record.
      autoCancel: true,
    ),
  );

  for (final request in requests) {
    await _plugin.show(
      // Stable per request, so a re-post replaces rather than stacks.
      id: request.id.hashCode,
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
