/// The baseline notification tier (PLAN.md §5).
///
/// ## Why WorkManager rather than a foreground service
///
/// The obvious shape — a `dataSync` foreground service polling around the clock — is
/// wrong twice over. Android 15 caps `dataSync` at **6 hours per 24 shared across all of
/// an app's services**, so a round-the-clock poller is deaf for three quarters of the
/// day; and Google documents `dataSync` as heading for deprecation with WorkManager named
/// as the replacement.
///
/// WorkManager has a 15-minute floor (anything shorter is silently clamped), no 6-hour
/// cap, no persistent notification and no Play foreground-service declaration. The honest
/// promise is therefore *"you'll hear about a request within about fifteen minutes"* —
/// and the copy in the app says exactly that rather than implying immediacy.
///
/// A parent actively waiting for an answer opens the app, where the Requests screen polls
/// at 60 seconds.
library;

import 'package:workmanager/workmanager.dart';

import '../pairing/secure_identity_store.dart';
import 'background_session.dart';
import 'notifications.dart';
import 'poll_logic.dart';

/// Re-exported so callers need only one import for the baseline tier.
export 'poll_logic.dart' show pollInterval, pollOnce;

/// Identifies the periodic task to WorkManager. Re-registering with the same name
/// replaces the existing schedule rather than adding a second one.
const String periodicTaskUniqueName = 'nestwatch.time-requests.periodic';

/// The name handed to the callback, so one dispatcher can serve several task kinds.
const String pollTaskName = 'poll-time-requests';

/// The background entry point.
///
/// `@pragma('vm:entry-point')` is required: this function is never called from Dart, so
/// tree-shaking would otherwise remove it from a release build — and the failure shows up
/// only in release, only on a real device, as "the task never runs".
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != pollTaskName) return true;
    try {
      return await runBackgroundPoll();
    } on Object {
      // Returning false asks WorkManager to retry with backoff. For a poll that repeats
      // in fifteen minutes anyway, a retry storm is worse than a missed round, so a
      // failed poll is reported as done.
      return true;
    }
  });
}

/// One poll against the paired server, using the real notification channel.
Future<bool> runBackgroundPoll() async {
  // Installs the pin in THIS isolate. See background_session.dart — statics do not
  // cross isolates, so without this the poll would run unpinned.
  final session = await openBackgroundSession();
  // Not paired, or not signed in: nothing to do, and not an error.
  if (session == null) {
    return true;
  }

  await pollOnce(
    client: session.client,
    store: const SecureSeenRequestStore(),
    notify: notifyTimeRequests,
    cancel: cancelForRequest,
  );

  // Always true, and stated here rather than inside `pollOnce` because this is the only
  // frame that WorkManager is listening to. False asks for a retry with backoff, and
  // there is nothing here worth retrying sooner than the next fifteen-minute round: an
  // unreachable PC means the phone is out of the house, and a lapsed session is fixed by
  // typing a password, which cannot happen in the background. Either way a retry storm
  // is the only thing false would buy.
  return true;
}

/// Register the periodic poll. Idempotent: the unique name replaces any existing
/// schedule rather than adding a second.
Future<void> enableBackgroundPolling() => Workmanager().registerPeriodicTask(
  periodicTaskUniqueName,
  pollTaskName,
  frequency: pollInterval,
  existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  constraints: Constraints(
    // No point waking to poll a LAN server with no network at all.
    networkType: NetworkType.connected,
    requiresBatteryNotLow: true,
  ),
);

Future<void> disableBackgroundPolling() =>
    Workmanager().cancelByUniqueName(periodicTaskUniqueName);
