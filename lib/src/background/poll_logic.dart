/// The decision half of the baseline poll: what is new, what is gone.
///
/// Deliberately free of `workmanager` and `flutter_local_notifications`. Both drag in
/// platform code — the notification plugin's Windows and Linux implementations use
/// `NativeCallable`, which crashes the VM's FFI transformer outright under a plain
/// `dart run` — and this is the part worth proving against a live server on every change.
/// The transport is injected; see `background_poll.dart` for the wiring.
library;

import '../api/models.dart';
import '../api/nestwatch_api.dart';
import 'seen_requests.dart';

/// WorkManager's floor on Android. Anything smaller is clamped without complaint, so
/// asking for less would be a promise the platform quietly declines to keep.
const Duration pollInterval = Duration(minutes: 15);

/// One poll, with everything it touches passed in.
///
/// Separated from [runBackgroundPoll] so it can be run against a live server without
/// WorkManager and without a notification channel — [notify] and [cancel] are platform
/// calls that need an Android binding, and everything interesting here is the logic
/// around them.
Future<bool> pollOnce({
  required NestwatchClient client,
  required SeenRequestStore store,
  required Future<void> Function(List<TimeRequest>) notify,
  required Future<void> Function(String id) cancel,
}) async {
  final List<TimeRequest> pending;
  try {
    pending = await client.timeRequests();
  } on NestwatchException {
    // A lapsed session or an unreachable PC is ordinary in the background: the phone may
    // simply be away from home, where `require_lan_peer` answers 403 before any auth
    // work. Nothing is shown for it — a notification saying "could not reach the PC"
    // every fifteen minutes while a parent is at work would be worse than silence, and
    // §5 is clear that a 401 means re-prompt for the password at next launch, not now.
    return true;
  }

  final seen = await store.load();
  final diff = diffPending(pending.map((r) => r.id), seen);

  // Persist BEFORE notifying. A crash between the two re-notifies on the next round,
  // and "told twice" is the worse failure: it is what teaches a parent to swipe the
  // notification away unread.
  await store.save(diff.next);

  // Anything that left the queue was resolved somewhere — here, in the browser
  // dashboard, or on another phone. Take its notification down.
  for (final goneId in seen.difference(diff.next)) {
    await cancel(goneId);
  }

  if (diff.fresh.isEmpty) return true;
  await notify(pending.where((r) => diff.fresh.contains(r.id)).toList());
  return true;
}
