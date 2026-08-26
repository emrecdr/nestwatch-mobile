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
Future<void> pollOnce({
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
    return;
  }

  final seen = await store.load();
  final diff = diffPending(pending.map((r) => r.id), seen);

  // Anything that left the queue was resolved somewhere — here, in the browser
  // dashboard, or on another phone. Take its notification down. This goes first
  // regardless of the ordering below: cancelling for something already resolved is safe
  // in any order, and doing it before the save keeps `seen` meaning "what the parent has
  // been told about" at every point in this function.
  for (final goneId in seen.difference(diff.next)) {
    await cancel(goneId);
  }

  // Announce BEFORE recording, and record only what was announced.
  //
  // This was the other way round, defended by a comment describing the *opposite*
  // ordering's failure. `diffPending` returns every pending id as `next`, so saving
  // first marks a request seen before the parent is told; a `notify` that then throws
  // leaves `fresh` empty on every later poll and the request is never announced at all.
  // `callbackDispatcher` catches `on Object` and reports success, so that loss has no
  // symptom — no retry, no log line, nothing, while a child waits for an answer.
  //
  // "Told twice" is the cost of *this* ordering, and it is the cheaper one. Announcing
  // first is at-least-once delivery with idempotent processing, which is also what
  // WorkManager already assumes since it may re-run a task; and the idempotency is
  // already here, because notifications are posted under `request.id.hashCode`, stable
  // per request, so Android replaces rather than stacks. A repeat costs one re-alert on
  // a single notification.
  //
  // The asymmetry decides it: announcing first is self-healing — a round that fails to
  // record simply announces again next time — where persisting first is not.
  if (diff.fresh.isNotEmpty) {
    await notify(pending.where((r) => diff.fresh.contains(r.id)).toList());
  }

  // Reached only once the announcement succeeded. A throw above leaves the store
  // untouched, which is what makes the next round a retry rather than a loss.
  await store.save(diff.next);
}
