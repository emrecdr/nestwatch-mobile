/// Whether the parent has already been told this phone needs signing in again.
///
/// ## Why a stored flag, and not the notification itself
///
/// The obvious design is to post the notice on every failed poll and let Android's
/// same-id replacement collapse them. It does collapse them — but a notice the parent
/// *swipes away* is gone, so the next round posts a new one and alerts again. Every
/// fifteen minutes, for as long as the session stays lapsed, which is until they act.
/// `notifications.dart` already records what that costs: "a notification that reappears
/// every fifteen minutes teaches a parent to dismiss it unread". This is that same
/// lesson, and [SeenRequestStore] is the same answer applied to time requests.
///
/// ## Why it cannot be derived from the session being gone
///
/// A tempting shortcut: a lapsed session clears the cookie, `SecureSessionStore` drops
/// it, and `openBackgroundSession` then returns null — so `pollOnce` stops running and
/// the announcement happens exactly once for free. That is true of **one** of the four
/// ways a 401 now arrives, and was checked rather than assumed:
///
///   * the 0.7.0 absolute age cap calls `session.flush()`, which does clear it;
///   * a session revoked from the *Signed-in devices* card does not go through that path;
///   * an idle expiry drops the record on that side, not this one;
///   * a pre-0.6.0 unscoped session is refused by `require_auth` with no flush at all —
///     it 401s forever while this phone holds a cookie it will never stop sending.
///
/// Three of the four keep polling, so the free latch would have been a latch on one case
/// and a fifteen-minute alarm on the rest.
library;

/// Remembers one bit across polls, each of which runs in a fresh isolate.
abstract class SignInNoticeStore {
  /// Has the parent already been told?
  Future<bool> announced();

  /// Record that they have. Idempotent.
  Future<void> markAnnounced();

  /// Re-arm, once the session works again — so the *next* lapse is announced too.
  Future<void> clear();
}

/// For tests and for a poll that has no storage. Holds the flag in this isolate only,
/// which means it forgets between rounds — correct for a test, useless in production,
/// and named so nobody wires it up by accident.
class InMemorySignInNotice implements SignInNoticeStore {
  bool _announced = false;

  @override
  Future<bool> announced() async => _announced;

  @override
  Future<void> markAnnounced() async => _announced = true;

  @override
  Future<void> clear() async => _announced = false;
}

/// The notice as one thing: where it is remembered, and the two calls that put it on the
/// screen and take it off again.
///
/// Bundled because the three are only ever correct together — a store updated without the
/// notification posted is a parent never told, and a notification posted without the store
/// updated is the fifteen-minute alarm this whole file exists to prevent. Passing them
/// separately made that a rule `pollOnce` had to remember; here it is a rule that has one
/// home and its own tests.
class SignInNotice {
  final SignInNoticeStore store;
  final Future<void> Function() announce;
  final Future<void> Function() withdraw;

  const SignInNotice({
    required this.store,
    required this.announce,
    required this.withdraw,
  });

  /// A notice that records instead of posting.
  ///
  /// For tests and for the `tool/prove_*` harnesses, which run under a plain `dart run`
  /// with no notification channel to post to. Pass [log] to assert on what happened; the
  /// strings are the whole point of it, so they are stated here rather than in each test.
  ///
  /// Not a silent no-op, deliberately. A default that discarded the calls would let a new
  /// call site opt out of this behaviour without saying so — the shape
  /// `notification_actions.dart` already had to be corrected for, where a path that
  /// decided nothing defaulted to saying nothing.
  factory SignInNotice.recording([List<String>? log]) {
    final store = InMemorySignInNotice();
    return SignInNotice(
      store: store,
      announce: () async => log?.add(raised),
      withdraw: () async => log?.add(lowered),
    );
  }

  /// What [SignInNotice.recording] logs. Named so a test asserts on a constant rather
  /// than on a string it retyped.
  static const String raised = 'sign-in notice raised';
  static const String lowered = 'sign-in notice lowered';

  /// Tell the parent, at most once per lapse.
  ///
  /// Announces **before** recording, deliberately. The other order silences a
  /// notification that then fails to post — permanently, since the flag would already say
  /// it had been — and with no symptom, because the background isolate reports success
  /// either way. The cost of this order is a repeat if the record fails, which is one
  /// extra notification that replaces itself.
  Future<void> raise() async {
    if (await store.announced()) return;
    await announce();
    await store.markAnnounced();
  }

  /// Take it down once the session works again, and re-arm for the next lapse.
  ///
  /// Withdraws before clearing, for the mirror of the reason above: clearing first would
  /// leave a stale notice on screen with nothing left that knows to remove it.
  Future<void> lower() async {
    if (!await store.announced()) return;
    await withdraw();
    await store.clear();
  }
}
