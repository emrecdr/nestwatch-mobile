/// The opt-in "watch now" tier (PLAN.md §5).
///
/// A `dataSync` foreground service the parent starts when they are *actively waiting*
/// for an answer, polling at 60 seconds instead of the baseline's fifteen minutes. It is
/// opt-in, and short, for one reason:
///
/// > Android 15 caps `dataSync` at **6 hours per 24**, shared across every one of the
/// > app's services, and only counts time while the app is in the background. On
/// > exceeding it the system calls `Service.onTimeout(int, int)` and allows a few
/// > seconds to `stopSelf()` before throwing `RemoteServiceException`.
///
/// §5 is emphatic that `onTimeout` must be handled **from the start** rather than after
/// the first crash report. `flutter_foreground_task` 11 implements both overloads and
/// calls `stopForegroundService()` from each — verified by reading
/// `ForegroundService.kt`, not assumed.
///
/// ## The default that would have undone that
///
/// `allowAutoRestart` defaults to `true`, and `ForegroundService.onDestroy` restarts the
/// service when `allowAutoRestart && !isCorrectlyStopped`. `isCorrectlyStopped()` is true
/// only when the *Dart* side called `stopService()` — the stored action is `API_STOP`. A
/// system timeout leaves it at `API_START`.
///
/// So on the default settings the sequence is: hit the 6-hour cap → `onTimeout` →
/// `stopSelf()` → `onDestroy` sees an "incorrect" stop → restart alarm in 5 seconds →
/// relaunch already over budget → timed out again. A restart loop against a system that
/// just told the app to stop, arrived at *through* a correct `onTimeout`.
///
/// [_options] therefore sets `allowAutoRestart: false`. That is the right shape here
/// anyway: watching is something a parent starts deliberately and briefly, and
/// auto-restart exists for always-on trackers — precisely the design §5 rejects.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'background_session.dart';

/// How long a watch session runs before stopping itself.
///
/// Well inside the 6-hour daily budget, and chosen for what the feature is rather than
/// what the platform allows: a parent waiting for an answer waits minutes, not hours. A
/// session that quietly consumed the whole day's allowance would leave the *next* one
/// unable to start at all.
const Duration watchSessionLimit = Duration(minutes: 30);

/// Poll cadence while watching. Matches the dashboard's `_pollMs`, and the Requests
/// screen's own cadence, so a watching phone and an open dashboard agree.
const Duration watchPollInterval = Duration(seconds: 60);

const _notificationChannelId = 'nestwatch.watching';

/// Is a watch session running right now?
Future<bool> isWatching() => FlutterForegroundTask.isRunningService;

/// Prepare the service. Must run before [startWatching]; cheap to repeat.
void initWatchService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: _notificationChannelId,
      channelName: 'Watching for requests',
      channelDescription:
          'Shown while Nestwatch is actively checking for time requests.',
      // Low importance: this notification exists because Android requires a foreground
      // service to have one, and because Play's monitoring-app policy wants a visible
      // indicator while the app is running. It is a status line, not an alert — the
      // alert is the separate time-request notification.
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(
        watchPollInterval.inMilliseconds,
      ),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      // Load-bearing. See the library docs: leaving this true turns a correct
      // onTimeout() into a five-second restart loop against the 6-hour cap.
      allowAutoRestart: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// Start watching. Returns false if the service could not be started.
Future<bool> startWatching(String authority) async {
  if (await FlutterForegroundTask.isRunningService) return true;

  final result = await FlutterForegroundTask.startService(
    serviceTypes: const [ForegroundServiceTypes.dataSync],
    notificationTitle: 'Watching $authority',
    notificationText:
        'Checking every minute. Stops on its own after '
        '${watchSessionLimit.inMinutes} minutes.',
    callback: watchTaskEntrypoint,
  );
  return result is ServiceRequestSuccess;
}

Future<bool> stopWatching() async {
  final result = await FlutterForegroundTask.stopService();
  return result is ServiceRequestSuccess;
}

/// The service's Dart entry point.
///
/// `@pragma('vm:entry-point')` is required: nothing in Dart calls this, so tree-shaking
/// would remove it from a release build, and the failure would appear only in release,
/// on a real device, as "watching does nothing".
@pragma('vm:entry-point')
void watchTaskEntrypoint() {
  FlutterForegroundTask.setTaskHandler(_WatchTaskHandler());
}

/// Runs inside the foreground service's own isolate.
class _WatchTaskHandler extends TaskHandler {
  DateTime? _startedAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _startedAt = timestamp;
    // Nothing here can assume the pin: a foreground task runs in its own isolate, and
    // `HttpOverrides._global` is a per-isolate static. `openBackgroundSession` installs
    // it — see background_session.dart. Same rule as the WorkManager tier.
    //
    // Deliberately not awaited into a stored client: each poll rebuilds the session so
    // a cookie re-issued by the sliding expiry (or a sign-out in the UI isolate) is
    // picked up rather than being held stale for the whole session.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_tick(timestamp));
  }

  Future<void> _tick(DateTime timestamp) async {
    final started = _startedAt;
    if (started != null && timestamp.difference(started) >= watchSessionLimit) {
      // Stop well inside the 6-hour daily budget rather than being stopped at it. A
      // session that ran to the cap would leave the next one unable to start at all.
      await FlutterForegroundTask.stopService();
      return;
    }

    // Unpaired or signed out — watching cannot mean anything. Stop rather than leaving
    // a persistent notification claiming to watch nothing.
    if (!await pollPairedServer()) await FlutterForegroundTask.stopService();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    if (!isTimeout) return;
    // The system hit the 6-hour dataSync cap and asked the service to stop. It already
    // has. Nothing is retried and nothing restarts: `allowAutoRestart` is false for
    // exactly this moment, and coming straight back would be immediately over budget.
    debugPrint(
      'nestwatch: watch session ended by the Android 15 dataSync timeout. '
      'The daily foreground budget is spent; the 15-minute background poll continues.',
    );
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}
