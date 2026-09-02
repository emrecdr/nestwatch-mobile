/// `GET /api/events` — the stream that tells this app when to stop guessing.
///
/// ## What nestwatch sends
///
/// A `text/event-stream` of bare tags, added in 0.4.0:
///
/// ```
/// event: requests
/// data: 1
///
/// ```
///
/// No payload. `data` is always the literal `1`; the tag is the whole message, and the
/// answer to it is to refetch through the ordinary endpoint. Three tags exist —
/// `requests`, `usage`, and `all`, the last sent when a subscriber has fallen behind and
/// lost tags, meaning "refetch everything". The set is closed on that side by a
/// `debug_assert` naming the client's own listeners.
///
/// ## Why this is worth having
///
/// PLAN §7 deferred long-polling because "it changes server behaviour for a client that
/// does not exist yet. Revisit once the app is real." The app is real, and the behaviour
/// changed anyway — for nestwatch's own dashboard. Watch-now polls every 60 s for a queue
/// that changes a few times a day: one held connection replaces about sixty requests an
/// hour and takes worst-case latency from a minute to about a second.
///
/// It does **not** replace polling. The poll stays as the backstop, because a stream that
/// dies quietly is indistinguishable from a house where nothing is happening — which is
/// the failure this repo keeps finding in its own checks, and it would be a poor thing to
/// build one on purpose.
library;

import 'dart:async';
import 'dart:convert';

import 'nestwatch_api.dart';

/// Parse a `text/event-stream` body into the name of each dispatched event.
///
/// Written to the spec rather than to what nestwatch happens to send, because the two
/// disagree in one place that matters: **an event with no `data` field is not dispatched
/// at all.** nestwatch always sends `data: 1`, so today the distinction is invisible —
/// but a parser that dispatched on the `event:` line alone would also dispatch on the
/// keep-alive comments, and then a silent connection would look like a busy one.
///
/// Line splitting is [LineSplitter]'s job, and the buffering that goes with it: a tag can
/// arrive split across two TCP reads, and `event: requ` / `ests` must not become two
/// events. Same for [Utf8Decoder] and a multi-byte character split down the middle.
Stream<String> serverSentEventNames(Stream<List<int>> body) async* {
  final lines = body.transform(utf8.decoder).transform(const LineSplitter());

  // Per-event accumulation. Local to this generator, so two connections cannot see each
  // other's half-built event — which a transformer holding state outside its bind callback
  // would allow, and which nothing here would have made obvious.
  var name = '';
  var hasData = false;

  await for (final line in lines) {
    // A blank line dispatches whatever has accumulated.
    if (line.isEmpty) {
      if (hasData) yield name.isEmpty ? 'message' : name;
      name = '';
      hasData = false;
      continue;
    }

    // `:` opens a comment — a keep-alive, which axum sends on an idle stream so the OS
    // does not drop a connection that is working correctly.
    //
    // **This branch is redundant, and is kept for the reader rather than for the
    // parser.** Measured rather than assumed: deleting it leaves every test in
    // `server_events_test.dart` passing. A line starting with `:` has its colon at index
    // 0, so the field name is the empty string and matches neither `event` nor `data` —
    // and dispatch is gated on `hasData` either way.
    //
    // It stays because somebody scanning for "what stops a keep-alive counting as news"
    // should find something here. It says outright that it is not that thing, so nobody
    // removes the gate above believing this covers them. The mutation audit holds the
    // gate; nothing holds this line, and nothing needs to.
    if (line.startsWith(':')) continue;

    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    // Exactly one leading space is part of the framing, not the value.
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        name = value;
      case 'data':
        hasData = true;
      // `id` and `retry` are spec fields nestwatch does not send. Ignored rather than
      // rejected: an unknown field must not break the stream, which is the property that
      // lets that side add one without this side shipping first.
    }
  }
}

/// The tags this app knows how to act on.
///
/// `all` is not in here because it is not a subject — it means *every* subject, and the
/// caller expands it. Keeping it out of this set stops a screen subscribing to "all" as
/// though it were a topic of its own.
const String requestsSubject = 'requests';
const String usageSubject = 'usage';
const Set<String> knownEventTags = {requestsSubject, usageSubject};

/// The subjects a tag invalidates.
///
/// One place, because the mapping is a claim about the server: approving a request
/// changes both the queue and today's minutes, and nestwatch says so by sending both
/// tags at that call site. `all` fans out to everything.
Set<String> subjectsOf(String tag) => tag == 'all'
    ? knownEventTags
    : (knownEventTags.contains(tag) ? {tag} : const {});

/// One live subscription to `GET /api/events`, reconnected as needed.
///
/// ## Why this is not a `Poller`
///
/// [Poller] answers "how often should I ask?". This answers "am I still being told?", and
/// the two failure modes are opposite: a poller that stops is silent for one interval,
/// while a stream that stops is silent forever and looks exactly like a quiet house. So
/// this never becomes the only source of truth — it exists to make the poll underneath it
/// arrive early, and [isReceiving] is exposed so a screen can say which it is living on.
///
/// ## Backoff
///
/// A dropped stream is ordinary: a phone sleeps, Wi-Fi hands over, that PC restarts. The
/// first retry is immediate because the common case is a handover that has already
/// finished, and doubling from a second to a cap of thirty keeps a PC that is genuinely
/// off from being asked sixty times a minute. Any successful *event* resets it — not a
/// successful connect, which a server that accepts and immediately closes would also
/// satisfy, turning backoff into a busy loop that reports itself as healthy.
class ServerEvents {
  /// Opens a fresh stream. A function rather than a client so the caller can hand over a
  /// re-created client after a re-pair without this object outliving its pin.
  final Stream<String> Function() open;

  /// Called with each subject that needs refetching, already expanded through
  /// [subjectsOf] — so `all` arrives as every subject rather than as a word to interpret.
  final void Function(String subject) onChanged;

  /// Called when the **session** has lapsed, and only then.
  ///
  /// Named for the one thing it means, because the previous name did not. It was
  /// `onFatal`, which is true of two different failures — a lapsed session and an
  /// endpoint that will never exist — and the only caller wired it to `signOut()` with
  /// the comment "a 401 here means what it means anywhere else". That comment is correct
  /// about the 401 and silent about the 404, which took the same exit: a PC running a
  /// nestwatch older than 0.4.0 answers 404 to `/api/events` forever, so the parent was
  /// signed out of a working server, typed the password, and was signed out again on the
  /// next mount. A loop with no state that ends it.
  ///
  /// The failure that is permanent for the *stream* is not therefore permanent for the
  /// *session*, and a callback that cannot tell a caller which one happened invites
  /// exactly that conflation. This one can only mean the session.
  final void Function(Object error)? onSessionLost;

  static const Duration _firstBackoff = Duration(seconds: 1);

  /// Longer than the poll it sits beside, deliberately.
  ///
  /// At 30 s a PC that is simply switched off was asked *twice a minute* — more traffic
  /// than the 60 s poll this was meant to relieve, and the exact opposite of the point.
  /// Freshness costs nothing here: the poll is the backstop, so a stream that takes two
  /// minutes to notice the PC is back has lost nothing a parent can see.
  static const Duration _maxBackoff = Duration(minutes: 2);

  StreamSubscription<String>? _sub;
  Timer? _retry;
  Duration _backoff = _firstBackoff;
  bool _wanted = false;
  bool _receiving = false;

  ServerEvents({
    required this.open,
    required this.onChanged,
    this.onSessionLost,
  });

  /// Whether a stream is currently delivering. False while retrying, and false before the
  /// first connection — a screen that claims live updates it is not receiving is worse
  /// than one that admits to polling.
  bool get isReceiving => _receiving;

  void start() {
    if (_wanted) return;
    _wanted = true;
    _connect();
  }

  void stop() {
    _wanted = false;
    _receiving = false;
    _retry?.cancel();
    _retry = null;
    _sub?.cancel();
    _sub = null;
  }

  void _connect() {
    if (!_wanted) return;
    _sub?.cancel();
    _sub = open().listen(
      (tag) {
        _receiving = true;
        _backoff = _firstBackoff;
        for (final subject in subjectsOf(tag)) {
          onChanged(subject);
        }
      },
      onError: (Object error) {
        _receiving = false;
        // Two failures another connection cannot fix, wanting two different answers.
        //
        // Both stop the stream: retrying either hammers a PC that is answering
        // correctly. Only the lapsed session is handed up, because only that one is a
        // fact about the parent's sign-in. A PC too old to have the endpoint is a PC
        // this app works against on every other route — the 60 s poll underneath is
        // precisely the backstop for a stream that is not there, and `ContractCheck` has
        // already told the parent the two versions disagree. Signing them out over it
        // took away an app that was working.
        if (error is NestwatchException && _isPermanent(error.failure)) {
          stop();
          if (error.failure == NestwatchFailure.sessionExpired) {
            onSessionLost?.call(error);
          }
          return;
        }
        _scheduleRetry();
      },
      // A clean end is still an end: the stream is gone and nothing will arrive on it.
      onDone: () {
        _receiving = false;
        _scheduleRetry();
      },
      cancelOnError: true,
    );
  }

  /// Failures another connection cannot fix.
  ///
  /// A lapsed session is one: reconnecting hammers a PC that is answering 401 perfectly
  /// correctly. **A missing endpoint is the other**, and it is the one that matters in
  /// practice — `/api/events` arrived in nestwatch 0.4.0, so every older PC answers 404
  /// forever. Retried, that is a request every couple of minutes for the life of the
  /// app, against a server that will never grow the route while it is running. The
  /// version check already tells the parent their PC is behind; this just stops asking.
  static bool _isPermanent(NestwatchFailure failure) =>
      failure == NestwatchFailure.sessionExpired ||
      failure == NestwatchFailure.unexpectedResponse;

  void _scheduleRetry() {
    if (!_wanted || _retry != null) return;
    final wait = _backoff;
    _backoff = wait * 2 > _maxBackoff ? _maxBackoff : wait * 2;
    _retry = Timer(wait, () {
      _retry = null;
      _connect();
    });
  }
}
