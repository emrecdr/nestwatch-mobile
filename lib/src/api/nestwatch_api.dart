/// The few nestwatch endpoints this app talks to.
///
/// Every request goes through `dart:io`'s `HttpClient`, which is pinned process-wide by
/// `HttpOverrides.global`. There is deliberately no way to configure a client here — a
/// second way to make requests would be a second way to make unpinned ones.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'reachability.dart';
import 'server_events.dart';
import 'session_cookie.dart';

/// One screenshot, and what the server said it actually sent.
///
/// The tier is returned alongside the bytes rather than checked and thrown on. A frame
/// served at the wrong tier is still a real, current picture of the child's screen, and
/// dropping it serves nobody — the runaway cost is the *stream*, not the frame, so the
/// caller stops the timer and shows what it has.
class Frame {
  final Uint8List bytes;

  /// From `X-Shot-Tier`, which names the tier actually served rather than the one asked
  /// for. `null` on a server predating the header.
  final String? servedTier;

  const Frame({required this.bytes, required this.servedTier});

  /// True when the server gave what was asked for, or did not say.
  bool get isPreview => servedTier == null || servedTier == 'preview';
}

/// One answer to a time request, and what that PC said about whether it will hold.
///
/// Built for the same reason as [Frame] — the server knows something about what it just
/// did that this app cannot work out for itself, and dropping it reports a success that is
/// not one.
///
/// Deliberately **not** a shared generic, and not the same shape either: `Frame.bytes` is
/// a payload that `servedTier` annotates, where `acted` *is* the status. A type over both
/// would carry no behaviour and would couple two unrelated endpoints, so the resemblance
/// is in the argument rather than in the fields. Said here because the earlier wording
/// ("same shape as") invited exactly that unification.
///
/// This used to be a bare `bool`. `_resolveTimeRequest` read the status, discarded the
/// body with `final (response, _)`, and returned whether the call had acted — so
/// `curfew_note`, which nestwatch computes precisely to stop a parent believing a grant
/// took effect, arrived on every approve and was never named anywhere in this repo.
class Decision {
  /// True when this call is the one that resolved the request, false when somebody had
  /// already answered it — the browser, another phone, or a second tap.
  final bool acted;

  /// `curfew_note`: set when bedtime will swallow the minutes just granted.
  ///
  /// nestwatch computes it against its own trusted clock, so it cannot disagree with the
  /// enforcer about whether a window is open — which is exactly why this app must not
  /// re-derive it. Screen time and bedtime are independent limits, and approving a
  /// request during a curfew window "looked like it would work and did not" (nestwatch
  /// `api::extend_curfew`).
  ///
  /// Null in three different situations that all read the same way — nothing to add:
  /// nothing is in the way; the call was a deny (**measured 2026-09-02** against 0.5.1:
  /// deny answers a bare `{"ok":true}` and carries no note); or the PC predates the
  /// field. A client must not turn a server that did not answer into a warning it
  /// invented.
  final String? curfewNote;

  const Decision({required this.acted, this.curfewNote});
}

/// `GET /session` — unauthenticated and LAN-gated (nestwatch `auth::me`).
///
/// §5 picks this as the first call for three reasons at once: it needs no credentials,
/// so it can run before pairing; it is refused off-LAN by `require_lan_peer` before any
/// auth work; and it doubles as the pin probe, because reaching it at all means the
/// handshake was accepted.
class SessionInfo {
  final bool authenticated;
  final String version;

  /// What this pairing is worth, from nestwatch 0.6.0's `scope`.
  ///
  /// Null both for a caller with no session and for a session minted before scopes
  /// existed, which is why it is never read without [reportsScopes] beside it.
  final PairingScope? scope;

  /// Whether that PC sent a `scope` key **at all**.
  ///
  /// nestwatch went to deliberate trouble to make this answerable, and its reason is the
  /// reason to carry it: *"Reported as null rather than omitted, so a client can tell
  /// 'this build has no scopes' (field absent) from 'your session predates them' (field
  /// present, null) — the second needs re-pairing and the first does not."*
  ///
  /// A reader that only looked at the value would collapse those two, and the app's first
  /// version of this did — recovering the difference by asking `ContractCheck` whether that
  /// PC was older, which is an *inference from a version string* standing in for a fact the
  /// server states outright. The mutation audit found it: widening the version exemption
  /// survived, because no test distinguished a PC that is merely newer from one that is
  /// behind. Asking the payload is both simpler and exact.
  final bool reportsScopes;

  const SessionInfo({
    required this.authenticated,
    required this.version,
    this.scope,
    this.reportsScopes = false,
  });

  static SessionInfo fromJson(Map<String, dynamic> json) => SessionInfo(
    authenticated: json['authenticated'] as bool? ?? false,
    version: json['version'] as String? ?? 'unknown',
    scope: PairingScope.fromJson(json['scope']),
    // Presence, not value. Every nestwatch from 0.6.0 sends the key on every answer —
    // an object or an explicit null — so its absence identifies an older build exactly,
    // where a version comparison only guesses at one.
    reportsScopes: json.containsKey('scope'),
  );

  @override
  String toString() => 'SessionInfo(authenticated: $authenticated, $version)';
}

/// What a redeemed pairing is allowed to do, as that PC records it.
///
/// ## Why a phone has to look
///
/// A dashboard link and an integration link are **byte-identical in form** —
/// `https://host:port/p/TOKEN#fp=…` — because the scope lives in that PC's `pairing.json`
/// and never in the URL. So the two QR codes look the same, and a parent hands over
/// whichever was on screen.
///
/// Handed an integration pairing, this app used to pair *successfully* and then come apart
/// in a way that pointed at the wrong thing entirely. An integration session may reach
/// `POST /api/extra-time` and `GET /api/usage/today` and nothing else, so **Today would
/// work** while Requests, Screen and Codes each answered 403 — and every 403 in this app
/// was reported as "turn off your VPN". A parent would have seen live figures on one tab
/// and a network complaint on three, and no amount of turning the VPN off would have
/// changed it.
///
/// nestwatch's own note is that this "defends against a mistake, not an attacker": nothing
/// stops a client that declines to check, and the credential itself remains the guarantee —
/// an integration pairing *cannot* reach the rest of the API whatever any client believes.
/// What reading it buys is that an honest client can say which mistake was made.
enum PairingScope {
  /// Everything an authenticated parent can do. What `nestwatch pair` mints, what a
  /// password login is worth, and what every screen in this app needs.
  dashboard,

  /// One integration, allowed to push earned time and read today's total. Not this app.
  integration,

  /// A `kind` this build has never heard of.
  ///
  /// Its own case rather than folded into `integration`, because "bounded in some way I
  /// cannot name" and "bounded in the way I can" are different things to tell a parent —
  /// and folding an unknown into the *narrower* of the two known kinds would be this app
  /// inventing a bound the server never stated.
  unrecognised;

  /// `null` for absent, null, or a shape this cannot read.
  ///
  /// Absent means a server older than 0.6.0, and `null` means a session minted before
  /// scopes existed — which `require_auth` refuses anyway. Both are "no authority
  /// recorded", and neither may be read as permission.
  static PairingScope? fromJson(Object? raw) => switch (raw) {
    {'kind': 'dashboard'} => dashboard,
    {'kind': 'integration'} => integration,
    // A map that is a scope, carrying a kind this build cannot name.
    {'kind': _} => unrecognised,
    _ => null,
  };

  /// Whether this app can do its job with this pairing.
  ///
  /// Only [dashboard] qualifies, and `null` deliberately does **not**: on a 0.6.0 server a
  /// null scope beside an authenticated session means a pre-scopes session that
  /// `require_auth` refuses, so treating it as permission would be reading absence as
  /// consent. The caller checks the server's version before consulting this — see
  /// `PairingController._scopeRefusal`.
  bool get isDashboard => this == PairingScope.dashboard;
}

enum NestwatchFailure {
  /// The handshake was refused: the certificate did not match the pin.
  pinMismatch,

  /// `require_lan_peer` answered 403 with an empty body. PLAN.md §6 calls this out
  /// specifically: it is what a VPN active on the phone looks like, and the message must
  /// say so rather than "server unreachable".
  notOnLan,

  /// 403 with an `{"error": ...}` body: the request was refused for what this *pairing* is
  /// allowed to do, not for where the phone is.
  ///
  /// Separate from [notOnLan] because the remedy is the opposite kind of thing — re-pair
  /// with the parent code, rather than change anything about the network. Sharing one
  /// failure would mean sharing one sentence, and the sentence is the whole point.
  notPermitted,

  /// The password was wrong (401 from `/login`).
  badPassword,

  /// Locked out — 5 wrong tries in 60 seconds (`LoginLimiter::default`, nestwatch
  /// `src/auth.rs`). The same limiter also gates `/p/{token}`.
  rateLimited,

  /// The session lapsed. §5: re-prompt for the password, do NOT re-pair.
  sessionExpired,

  /// The thing acted on is no longer there — an approve or deny for a request that
  /// somebody already resolved. Not really a failure; see [NestwatchClient.approve].
  alreadyResolved,

  /// The PC reached us, understood the request, and could not carry it out.
  ///
  /// `AppError::Control` (nestwatch `src/error.rs`) covers every OS operation that can
  /// fail — capture, process list, kill, shutdown — and answers **500** with the OS
  /// detail logged rather than leaked, so the body says only `"operation failed"`. The
  /// status therefore says *which layer* gave up but never *why*, and the app has to
  /// supply the "why" from knowing which endpoint it called.
  operationFailed,

  unreachable,
  unexpectedResponse,
}

class NestwatchException implements Exception {
  final NestwatchFailure failure;
  final String message;

  /// The operating system's own words, when there were any.
  ///
  /// Kept off [message] on purpose: "No route to host" appended to a sentence written
  /// for a parent is noise they cannot act on. The harnesses print it, because there it
  /// is the most useful part.
  final String? detail;

  const NestwatchException(this.failure, this.message, {this.detail});

  @override
  String toString() => message;
}

/// A connection to one nestwatch server, carrying its session.
///
/// ## The cookie is applied by hand, on every request
///
/// PLAN.md §5 says Dart's `HttpClient` "already keeps an in-process cookie jar across
/// requests to the same server, so persistence is only needed across app launches".
/// **It does not.** Measured against 0.3.0: a `POST /login` that returns `200 {"ok":true}`
/// and a `Set-Cookie: hh_session=…` is followed, *on the very same client instance*, by a
/// `GET /session` answering `{"authenticated":false}`. `dart:io` exposes
/// `response.cookies` and `request.cookies` and stores nothing in between.
///
/// So the jar is here, and it is consulted for every request rather than only at launch.
class NestwatchClient {
  final String authority;
  final Duration timeout;

  SessionCookie? _cookie;

  /// One client, reused across requests.
  ///
  /// `dart:io` pools connections per `HttpClient`, so a client built per request means a
  /// full TLS handshake per request — three round trips and an RSA verification every
  /// five seconds while the live-view screen is open, against a PC on the same LAN.
  ///
  /// Reuse stays safe because the pin is enforced during the *handshake*: a pooled
  /// connection is one whose certificate already satisfied `badCertificateCallback`, so
  /// carrying a second request over it inherits that check rather than skipping one.
  ///
  /// What reuse must NOT survive is a change of pin. A pooled connection was established
  /// under whatever was trusted at the time, and re-pairing to a different certificate
  /// does not reach back into the pool. [close] therefore has to be called whenever the
  /// client is replaced — see `PairingController._clientFor`.
  HttpClient? _http;

  NestwatchClient(
    this.authority, {
    this._cookie,
    this.timeout = const Duration(seconds: 10),
  });

  SessionCookie? get cookie => _cookie;

  bool get hasSession => _cookie != null;

  HttpClient get _client => _http ??= HttpClient()
    ..connectionTimeout = timeout
    // The dashboard opens one connection and keeps it; matching that keeps a phone from
    // holding sockets open against a PC that is also serving a browser.
    ..maxConnectionsPerHost = 4
    ..idleTimeout = const Duration(seconds: 30);

  /// Drop the pooled connections. Required before this client outlives its pin.
  void close() {
    _http?.close(force: true);
    _http = null;
  }

  /// Called whenever the session changes, so it can be persisted.
  void Function(SessionCookie?)? onSessionChanged;

  /// Take whatever the response says about the session.
  void _adoptFrom(HttpClientResponse response) {
    final said = SessionCookie.readFrom(response);
    if (said.cleared) return _adopt(null);
    final issued = said.issued;
    if (issued != null) _adopt(issued);
  }

  void _adopt(SessionCookie? next) {
    if (next == _cookie) return;
    _cookie = next;
    onSessionChanged?.call(next);
  }

  /// `GET /session` → `{authenticated, version}`.
  Future<SessionInfo> session() async {
    final (response, body) = await _send('GET', '/session');
    // Not [_requireOk], deliberately. That maps 401 to sessionExpired, which is the right
    // reading everywhere behind `require_auth` and the wrong one here: `/session` is
    // unauthenticated, so a 401 from it would not mean a lapsed sign-in and telling a
    // parent to enter their password again would send them somewhere useless.
    if (response.statusCode != HttpStatus.ok) {
      throw NestwatchException(
        NestwatchFailure.unexpectedResponse,
        _unexpectedStatus(response),
      );
    }
    try {
      return SessionInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } on Object {
      throw const NestwatchException(
        NestwatchFailure.unexpectedResponse,
        'Something answered at that address, but it is not nestwatch.',
      );
    }
  }

  /// `GET /p/{token}` — redeem a pairing token.
  ///
  /// **Returns nothing, on purpose.** PLAN.md trap 2: `auth::pair` ends at
  /// `Redirect::to("/")` on every path — success, expired, already spent, wrong token —
  /// deliberately, so a guessed token is not an oracle. The status code therefore carries
  /// no information and this must not pretend otherwise. The caller learns whether it
  /// worked by asking `/session` afterwards, which is the only thing that knows.
  ///
  /// Redirects are not followed: doing so would fetch the whole dashboard SPA to learn
  /// nothing, since the answer is in the cookie, not the page.
  Future<void> redeemPairingToken(String token) async {
    await _send('GET', '/p/$token', followRedirects: false);
  }

  /// `POST /login` with `{"password": "…"}`.
  ///
  /// JSON, not a form: the handler takes `Json(body): Json<LoginRequest>`, so axum
  /// requires `Content-Type: application/json` and would answer 415 to a form post.
  Future<void> login(String password) async {
    final (response, _) = await _send(
      'POST',
      '/login',
      jsonBody: {'password': password},
    );

    switch (response.statusCode) {
      case HttpStatus.ok:
        return;
      case HttpStatus.unauthorized:
        throw const NestwatchException(
          NestwatchFailure.badPassword,
          'That password was not accepted.',
        );
      case HttpStatus.tooManyRequests:
        throw NestwatchException(
          NestwatchFailure.rateLimited,
          'Too many wrong attempts. That PC has stopped accepting tries for '
          '${LoginLimits.lockoutInWords()} — wait, then try again.',
        );
      default:
        throw NestwatchException(
          NestwatchFailure.unexpectedResponse,
          _unexpectedStatus(response),
        );
    }
  }

  /// `GET /api/events` → one connection's worth of change tags (nestwatch 0.4.0).
  ///
  /// Yields tag names until the connection ends, and ends with it — reconnecting is
  /// [ServerEvents]'s job, not this method's. Splitting it that way keeps the part that
  /// talks to that PC free of the part that decides how eagerly to try again.
  ///
  /// Deliberately **not** wrapped in [_mappingTransportFailures]. Everywhere else a
  /// dropped connection is a failure worth a sentence on a screen; here it is the
  /// expected end of a long-lived stream — a phone that slept, a Wi-Fi handover — and
  /// turning that into "that PC is unreachable" would put an alarm in front of a parent
  /// every time their phone changed rooms. The caller reconnects instead, and the 60 s
  /// poll underneath it is what actually guarantees the screen is not stale.
  ///
  /// The one failure that must not be swallowed is a lapsed session, which is why
  /// [_requireOk] still runs: a 401 here means the same thing it means anywhere else.
  Stream<String> events() async* {
    final response = await _open(
      'GET',
      '/api/events',
      accept: 'text/event-stream',
    );
    if (response.statusCode != HttpStatus.ok) {
      // Drain before throwing, or the socket is held until the idle timeout for a
      // response nobody will read. Everywhere else the body is consumed on the way to
      // the failure; here the stream is the return value, so nothing else would.
      await response.drain<void>();
      _requireOk(response);
    }
    yield* serverSentEventNames(response);
  }

  /// `GET /api/time-requests` → at most 5 pending, newest first.
  Future<List<TimeRequest>> timeRequests() async {
    final (response, body) = await _send('GET', '/api/time-requests');
    _requireOk(response);
    final list = jsonDecode(body) as List;
    return list
        .whereType<Map<String, dynamic>>()
        .map(TimeRequest.fromJson)
        .toList();
  }

  /// `POST /api/time-requests/{id}/approve`.
  ///
  /// [Decision.acted] is `true` when this call is the one that granted the minutes,
  /// `false` when the request had already been resolved; [Decision.curfewNote] carries
  /// what that PC said about whether the grant can actually take effect.
  ///
  /// That distinction exists because the server answers **400** — not 200 — to a second
  /// approve (`"no such pending request"`, confirmed on the wire). The mutex in
  /// `TimeRequests::resolve` makes the *grant* happen exactly once; it does not make the
  /// second call succeed. nestwatch's own comment records why the gate is there:
  /// "six concurrent approvals of one request all returned `Some` — so a parent
  /// double-tapping Approve on a phone granted the minutes twice".
  ///
  /// So a 400 here is an ordinary race, not something to show a parent. The screen
  /// refreshes instead.
  Future<Decision> approveTimeRequest(String id) =>
      _resolveTimeRequest(id, 'approve');

  /// `POST /api/time-requests/{id}/deny`. Same 400-means-already-resolved shape.
  Future<Decision> denyTimeRequest(String id) =>
      _resolveTimeRequest(id, 'deny');

  Future<Decision> _resolveTimeRequest(String id, String verb) async {
    final (response, body) = await _send(
      'POST',
      '/api/time-requests/${Uri.encodeComponent(id)}/$verb',
    );
    // A request somebody else already answered carries no advice about a grant that did
    // not happen here, so there is nothing to read out of this body.
    if (response.statusCode == HttpStatus.badRequest) {
      return const Decision(acted: false);
    }
    _requireOk(response);
    return Decision(
      acted: true,
      curfewNote: _stringOrNull(body, 'curfew_note'),
    );
  }

  /// One optional string field off a body that may not be JSON at all.
  ///
  /// The decode and its `try` are this method's whole job; what counts as "nothing said"
  /// is [nonEmptyString]'s, and lives once in `models.dart` because three copies of that
  /// rule is what this replaced. A body that does not parse reads the same as a field
  /// that is absent, which is the same as one that is blank — the server had nothing to
  /// add, and none of those may become a sentence in front of a parent.
  ///
  /// The failure worth avoiding is the opposite of the one that made this necessary:
  /// having discarded the server's words, the next mistake would be inventing some.
  static String? _stringOrNull(String body, String field) {
    try {
      return nonEmptyString((jsonDecode(body) as Map<String, dynamic>)[field]);
    } on Object {
      return null;
    }
  }

  /// `GET /api/time-codes` → the issued codes nobody has redeemed yet.
  Future<List<TimeCode>> timeCodes() async {
    final (response, body) = await _send('GET', '/api/time-codes');
    _requireOk(response);
    final list = jsonDecode(body) as List;
    return list
        .whereType<Map<String, dynamic>>()
        .map(TimeCode.fromJson)
        .toList();
  }

  /// `POST /api/time-codes` → mint one worth `minutes`.
  ///
  /// The server rejects anything outside 1..=[TimeCodeLimits.maxMinutes] and refuses
  /// once [TimeCodeLimits.maxActive] are outstanding — both as 400 with a body naming
  /// the reason, which is worth distinguishing because "too many active codes" is fixed
  /// by using some, and "minutes out of range" by asking for fewer.
  Future<TimeCode> issueTimeCode(int minutes) async {
    final (response, body) = await _send(
      'POST',
      '/api/time-codes',
      jsonBody: {'minutes': minutes},
    );
    if (response.statusCode == HttpStatus.badRequest) {
      final reason = _errorFrom(body);
      throw NestwatchException(
        NestwatchFailure.unexpectedResponse,
        reason.contains('too many')
            ? 'That PC already has the most codes it will hold '
                  '(${TimeCodeLimits.maxActive}). Use or wait out some of the ones '
                  'below before making another.'
            : 'That PC would not issue a code for $minutes minutes. It allows '
                  '1 to ${TimeCodeLimits.maxMinutes}.',
      );
    }
    _requireOk(response);
    final json = jsonDecode(body) as Map<String, dynamic>;
    return TimeCode(
      code: json['code'] as String? ?? '',
      ts: DateTime.now().toUtc().toIso8601String(),
      minutes: (json['minutes'] as num?)?.toInt() ?? minutes,
    );
  }

  /// What to say when a status code carries no more meaning than itself.
  static String _unexpectedStatus(HttpClientResponse response) =>
      'That PC answered with HTTP ${response.statusCode}.';

  /// nestwatch answers errors as `{"error": "..."}`; anything else is not from it.
  ///
  /// A thin adapter over [_stringOrNull] rather than a second decoder. It had its own
  /// copy of the same try/decode/one-field read, sixty lines from the newer one and
  /// disagreeing with it about blank — `''` there, `null` here. Its one caller asks
  /// `reason.contains('too many')`, which a whitespace-only string fails either way, so
  /// the two answers were never distinguishable at the only place that reads them.
  static String _errorFrom(String body) => _stringOrNull(body, 'error') ?? '';

  /// `GET /api/usage/today`.
  Future<UsageToday> usageToday() async {
    final (response, body) = await _send('GET', '/api/usage/today');
    _requireOk(response);
    return UsageToday.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// `GET /api/screenshot?tier=preview` → JPEG bytes.
  ///
  /// **Two query parameters, both mandatory, for two different reasons.**
  ///
  /// `tier=preview` is trap 4: `ShotTier::from_arg` maps unknown and absent alike to
  /// `Full`, so omitting it does not error — it quietly returns native-resolution frames.
  /// There is no `tier` argument on this method and no full-size equivalent, because an
  /// argument with a default is how the wrong tier gets sent.
  ///
  /// `live=1` is who asked. nestwatch audits **by asker, never by tier**: a frame a
  /// person requested writes one `screenshot_taken` row, and timer frames coalesce into
  /// a periodic `live_view` row carrying a count. The audit used to switch on tier, which
  /// held only while the timer always asked for previews; live frames now follow the
  /// visible surface, so the proxy broke. `audit.jsonl` rotates at 2 MiB with one backup,
  /// so a timer that omits `live` writes ~720 rows an hour and evicts every login, kill
  /// and password change to make room for itself.
  ///
  /// [onTimer] therefore has no default either. It is not "is this a live view" — it is
  /// "did a timer ask for this, or did a person", which is the question the audit is
  /// answering.
  Future<Frame> screenshotPreview({required bool onTimer}) async {
    final query = onTimer ? '?tier=preview&live=1' : '?tier=preview';
    return _mappingTransportFailures(() async {
      final response = await _open('GET', '/api/screenshot$query');
      // This is the one call site that knows the operation was a screen capture, so it
      // is the only place the 500 can be specific. Handed down rather than caught and
      // rewritten: the generic sentence was being produced and then thrown away, and
      // eighteen lines of this method were that round trip.
      _requireOk(
        response,
        whenOperationFails:
            'That PC could not take a picture of its screen.\n\n'
            'The usual cause is Windows being older than version 1903: below that build '
            'the screen-capture API is simply absent, and every screenshot fails while '
            'everything else on this app keeps working. Updating Windows on that PC '
            'fixes it.',
      );

      // The server names the tier it actually served, so a client can record what it
      // *got* rather than what it asked for. Reported rather than refused: a frame at the
      // wrong tier is still a real, current picture, and the cost worth guarding against
      // is the stream — which the caller stops — not the single frame. Absent on a server
      // predating the header, which reads as "no disagreement to report".
      final served = response.headers.value('x-shot-tier');
      final chunks = await response.toList();
      return Frame(
        bytes: Uint8List.fromList(chunks.expand((c) => c).toList()),
        servedTier: served,
      );
    });
  }

  /// Every `/api/*` path is behind `require_auth`, which answers 401 once the session
  /// lapses. §5 is explicit about what that means: re-prompt for the password, do NOT
  /// re-pair — the certificate is still trusted, only the session went.
  void _requireOk(HttpClientResponse response, {String? whenOperationFails}) {
    if (response.statusCode == HttpStatus.ok) return;
    if (response.statusCode == HttpStatus.unauthorized) {
      throw const NestwatchException(
        NestwatchFailure.sessionExpired,
        'That sign-in expired.',
      );
    }
    if (response.statusCode == HttpStatus.internalServerError) {
      // AppError::Control and AppError::Internal both land here, with the OS detail
      // logged on the server and deliberately not in the body — so this says which
      // layer gave up and never why. A caller that knows what it asked for can say more,
      // and passes that sentence in rather than catching this one to overwrite it.
      throw NestwatchException(
        NestwatchFailure.operationFailed,
        whenOperationFails ?? 'That PC could not carry out the request.',
      );
    }
    throw NestwatchException(
      NestwatchFailure.unexpectedResponse,
      _unexpectedStatus(response),
    );
  }

  /// A bare GET against `path`, for tests that need to drive a specific server
  /// response through the same code path a real call takes.
  ///
  /// Public rather than private because the alternative — reaching the 401 and
  /// Set-Cookie handling only through `session()` — would test them against a stub
  /// pretending to be `/session`, which is a weaker thing to assert. Not annotated
  /// `@visibleForTesting`: that would pull `package:meta` into a file kept deliberately
  /// free of dependencies beyond `dart:io`.
  Future<void> rawGetForTest(String path) async {
    final (response, _) = await _send('GET', path);
    _requireOk(response);
  }

  /// One request: attach the session, send, take what it says about the session.
  ///
  /// Separate from [_send] because [screenshotPreview] wants the same request and a
  /// different body — JPEG bytes rather than decoded text. It used to build its own, and
  /// the copy lacked the 403 branch below, so a phone behind a VPN was told
  /// "HTTP 403" instead of the thing §6 asks it to be told. One place builds a request.
  Future<HttpClientResponse> _open(
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    bool followRedirects = true,
    String? accept,
  }) async {
    final request = await _client
        .openUrl(method, Uri.parse('https://$authority$path'))
        .timeout(timeout);
    request.followRedirects = followRedirects;
    if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);

    final held = _cookie;
    if (held != null) request.cookies.add(held.toCookie());

    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(jsonBody));
    }

    final response = await request.close().timeout(timeout);

    // Adopt before inspecting the status: a 401 that also clears the cookie has to
    // drop the stored one, or the app retries forever with a dead session.
    _adoptFrom(response);

    if (response.statusCode == HttpStatus.forbidden) {
      // Two different refusals share this status, and they are told apart by the body.
      //
      // `require_lan_peer` returns a bare `StatusCode::FORBIDDEN` with nothing in it. The
      // scope gate returns `AppError::Forbidden`, which serialises as
      // `{"error": "..."}`. This used to `drain` the body and report the LAN sentence
      // either way — so an integration pairing, which may reach `usage/today` and nothing
      // else, produced a working Today tab beside three tabs telling a parent to turn off
      // a VPN that was never on.
      //
      // The body is read rather than the path inspected, because which paths an
      // integration may reach is that PC's rule and not this app's to mirror.
      final body = await response.transform(utf8.decoder).join();
      final said = _errorFrom(body);
      if (said.isNotEmpty) {
        throw NestwatchException(
          NestwatchFailure.notPermitted,
          'That PC refused this request because of what the pairing on this phone is '
          'allowed to do.\n\nIt said: "$said"\n\nThat is an integration pairing, not '
          'the parent one. Run `nestwatch pair` on that PC and scan the code it prints.',
          detail: said,
        );
      }
      throw const NestwatchException(
        NestwatchFailure.notOnLan,
        'That PC refused the connection because this phone does not look like it is '
        'on the same home network. If a VPN is switched on, turn it off — nestwatch '
        'only answers devices on the LAN.',
      );
    }

    return response;
  }

  /// The two failures that are about the wire rather than about the endpoint.
  ///
  /// Takes the whole call rather than wrapping [_open] alone, because reading the body is
  /// as much of the request as sending it: a connection dropped halfway through a
  /// response arrives as a [SocketException] from the *stream*, long after
  /// `HttpClientRequest.close` returned. Wrapping only the send would map the failures
  /// that happen before the first byte and let the ones after it through raw.
  Future<T> _mappingTransportFailures<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on HandshakeException {
      throw const NestwatchException(
        NestwatchFailure.pinMismatch,
        'The certificate did not match.',
      );
    } on SocketException catch (e) {
      // Ask this phone where it is before blaming that PC. For a LAN-only app the
      // commonest cause by far is a parent who left the house — which is not a fault,
      // and should not be reported as one, least of all in the OS's words.
      final where = whereAmI(
        serverHost: authority.split(':').first,
        localAddresses: await localAddresses(),
      );
      throw NestwatchException(
        NestwatchFailure.unreachable,
        explainUnreachable(where, authority),
        detail: e.osError?.message ?? e.message,
      );
    }
  }

  /// One request, read as text. Every endpoint but the screenshot wants this.
  Future<(HttpClientResponse, String)> _send(
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    bool followRedirects = true,
  }) => _mappingTransportFailures(() async {
    final response = await _open(
      method,
      path,
      jsonBody: jsonBody,
      followRedirects: followRedirects,
    );
    final body = await response.transform(utf8.decoder).join();
    return (response, body);
  });
}
