/// Which pending requests the parent has already been told about.
///
/// Without this the 15-minute poll re-notifies about the same request four times an
/// hour until somebody resolves it — which trains a parent to swipe the notification
/// away, which is the opposite of what it is for.
///
/// Ids are not secret, but they live in the same secure storage as everything else
/// rather than pulling in `shared_preferences` for one small list. The "one dependency
/// rule" is about `dart:io`, but every added package is also another audit.
///
/// The Keystore-backed implementation lives in `secure_identity_store.dart` with the
/// other platform-bound stores, so this file — and the poll logic that uses it — stays
/// runnable under a plain `dart run`.
library;

abstract class SeenRequestStore {
  Future<Set<String>> load();
  Future<void> save(Set<String> ids);
}

class InMemorySeenRequestStore implements SeenRequestStore {
  Set<String> _held = {};

  InMemorySeenRequestStore([Set<String>? initial]) : _held = initial ?? {};

  @override
  Future<Set<String>> load() async => _held;

  @override
  Future<void> save(Set<String> ids) async => _held = ids;
}

/// Decide what is new, and what the store should hold next.
///
/// Pruning to `pending` is the second half and is easy to leave out: an id that stays in
/// the set after its request is resolved is harmless, but if the *same* id could ever
/// come back it would be silently suppressed. Keeping the set equal to what is pending
/// means the set says exactly one thing — "these are the pending requests the parent has
/// seen" — rather than accumulating history nobody reads.
({Set<String> fresh, Set<String> next}) diffPending(
  Iterable<String> pendingIds,
  Set<String> alreadySeen,
) {
  final pending = pendingIds.toSet();
  return (fresh: pending.difference(alreadySeen), next: pending);
}
