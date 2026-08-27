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
Stream<String> serverSentEventNames(Stream<List<int>> body) {
  return body
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .transform(_dispatchTransformer);
}

final StreamTransformer<String, String>
_dispatchTransformer = StreamTransformer<String, String>.fromBind((lines) {
  var name = '';
  var hasData = false;

  return lines.expand((line) {
    // A blank line dispatches whatever has accumulated.
    if (line.isEmpty) {
      final dispatched = hasData
          ? [name.isEmpty ? 'message' : name]
          : const <String>[];
      name = '';
      hasData = false;
      return dispatched;
    }

    // `:` opens a comment. This is what a keep-alive looks like — axum sends one on
    // an idle stream so the OS does not drop a connection that is working correctly.
    // Treating it as an event would turn "nothing has happened" into a refetch loop.
    if (line.startsWith(':')) return const <String>[];

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
      // rejected: an unknown field must not break the stream, which is the property
      // that lets that side add one without this side shipping first.
    }
    return const <String>[];
  });
});

/// The tags this app knows how to act on.
///
/// `all` is not in here because it is not a subject — it means *every* subject, and the
/// caller expands it. Keeping it out of this set stops a screen subscribing to "all" as
/// though it were a topic of its own.
const Set<String> knownEventTags = {'requests', 'usage'};

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

  /// Called when a lapsed session is seen, which reconnecting cannot fix.
  final void Function(Object error)? onFatal;

  static const Duration _firstBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 30);

  StreamSubscription<String>? _sub;
  Timer? _retry;
  Duration _backoff = _firstBackoff;
  bool _wanted = false;
  bool _receiving = false;

  ServerEvents({required this.open, required this.onChanged, this.onFatal});

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
        // A lapsed session is not something another connection fixes. Handing it up
        // rather than retrying stops this quietly hammering a PC that is answering 401
        // perfectly correctly.
        if (error is NestwatchException &&
            error.failure == NestwatchFailure.sessionExpired) {
          stop();
          onFatal?.call(error);
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
