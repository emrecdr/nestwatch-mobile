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
///   * a pre-0.7.0 unscoped session is refused by `require_auth` with no flush at all —
///     it 401s forever while this phone holds a cookie it will never stop sending.
///
/// Three of the four keep polling, so the free latch would have been a latch on one case
/// and a fifteen-minute alarm on the rest.
library;

/// Remembers *when* across polls, each of which runs in a fresh isolate.
///
/// A timestamp rather than a bit, and the difference is a defect this shape used to have.
/// With a bit, "already told" was permanent until a poll succeeded — and a poll cannot
/// succeed while the session is the thing that is broken. So a parent who swiped the
/// notice away without acting was never told again, by anything, for as long as the lapse
/// lasted. The anti-nagging argument above is still right about fifteen minutes; it was
/// never an argument for *once, ever*. See [SignInNotice.renotifyAfter].
abstract class SignInNoticeStore {
  /// When the parent was last told, or null if they have not been.
  Future<DateTime?> announcedAt();

  /// Record that they have been told, at [at]. Idempotent; the newest time wins.
  Future<void> markAnnounced(DateTime at);

  /// Re-arm, once the session works again — so the *next* lapse is announced too.
  Future<void> clear();
}

/// For tests and for a poll that has no storage. Holds the time in this isolate only,
/// which means it forgets between rounds — correct for a test, useless in production,
/// and named so nobody wires it up by accident.
class InMemorySignInNotice implements SignInNoticeStore {
  DateTime? _at;

  @override
  Future<DateTime?> announcedAt() async => _at;

  @override
  Future<void> markAnnounced(DateTime at) async => _at = at;

  @override
  Future<void> clear() async => _at = null;
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
  /// How long a notice the parent has not acted on counts as already given.
  ///
  /// The two obvious values are both wrong. Every poll — fifteen minutes — is the alarm
  /// `notifications.dart` says "teaches a parent to dismiss it unread". Never again is
  /// what this was, and it loses the parent entirely the moment they swipe: the condition
  /// does not heal on its own, so silence after a dismissal is silence until they happen
  /// to open the app, which is exactly the state the notice exists to prevent.
  ///
  /// A day is the interval at which a repeat still reads as information rather than as
  /// nagging, and it matches what the condition actually is — a standing job that needs
  /// one action, not an event. At most one extra notification per day, and only while the
  /// phone genuinely cannot do the thing it was installed for.
  static const Duration renotifyAfter = Duration(days: 1);

  final SignInNoticeStore store;
  final Future<void> Function() announce;
  final Future<void> Function() withdraw;

  /// Injected for the same reason `PairingController` injects one: the rule below is
  /// about elapsed time, and a test that cannot move the clock can only ever check the
  /// branch it happens to be standing in.
  final DateTime Function() now;

  const SignInNotice({
    required this.store,
    required this.announce,
    required this.withdraw,
    this.now = DateTime.now,
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

  /// Tell the parent, at most once per [renotifyAfter].
  ///
  /// Announces **before** recording, deliberately. The other order silences a
  /// notification that then fails to post — permanently, since the record would already
  /// say it had been — and with no symptom, because the background isolate reports
  /// success either way. The cost of this order is a repeat if the record fails, which is
  /// one extra notification that replaces itself.
  Future<void> raise() async {
    final last = await store.announcedAt();
    // Read once. Called twice it is two different instants, and the one recorded would
    // not be the one the decision was made against.
    final moment = now();
    if (last != null && _alreadySaid(last, moment)) return;
    await announce();
    await store.markAnnounced(moment);
  }

  /// Take it down once the session works again, and re-arm for the next lapse.
  ///
  /// Withdraws before clearing, for the mirror of the reason above: clearing first would
  /// leave a stale notice on screen with nothing left that knows to remove it.
  ///
  /// Called from three places, and the two that are not the poll are the point. A parent
  /// who signs in from the launcher rather than from the notification, and a parent who
  /// presses "Forget this PC", have both ended the condition this describes — and until
  /// they were wired up, neither could take it down, because the only caller was a poll
  /// that has to *succeed* to reach it.
  Future<void> lower() async {
    if (await store.announcedAt() == null) return;
    await withdraw();
    await store.clear();
  }

  /// Whether a notice given at [last] still counts, as of [now].
  ///
  /// A **backwards** clock re-announces rather than staying quiet. Elapsed time is
  /// negative when the phone's clock moves back — a timezone database update, a manual
  /// change, a device that lost its battery — and `elapsed < renotifyAfter` is true of
  /// every negative duration, so the naive comparison would suppress the notice for as
  /// long as the clock stayed behind. One repeat is the cheap error here; indefinite
  /// silence is the expensive one, and this whole file exists because of it.
  static bool _alreadySaid(DateTime last, DateTime now) {
    final elapsed = now.difference(last);
    return !elapsed.isNegative && elapsed < renotifyAfter;
  }
}
