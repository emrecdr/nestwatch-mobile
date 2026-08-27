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

/// `GET /session` — unauthenticated and LAN-gated (nestwatch `auth::me`).
///
/// §5 picks this as the first call for three reasons at once: it needs no credentials,
/// so it can run before pairing; it is refused off-LAN by `require_lan_peer` before any
/// auth work; and it doubles as the pin probe, because reaching it at all means the
/// handshake was accepted.
class SessionInfo {
  final bool authenticated;
  final String version;

  const SessionInfo({required this.authenticated, required this.version});

  static SessionInfo fromJson(Map<String, dynamic> json) => SessionInfo(
    authenticated: json['authenticated'] as bool? ?? false,
    version: json['version'] as String? ?? 'unknown',
  );

  @override
  String toString() => 'SessionInfo(authenticated: $authenticated, $version)';
}

enum NestwatchFailure {
  /// The handshake was refused: the certificate did not match the pin.
  pinMismatch,

  /// `require_lan_peer` answered 403. PLAN.md §6 calls this out specifically: it is what
  /// a VPN active on the phone looks like, and the message must say so rather than
  /// "server unreachable".
  notOnLan,

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
  const NestwatchException(this.failure, this.message);

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
  /// Returns `true` when this call is the one that granted the minutes, `false` when the
  /// request had already been resolved.
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
  Future<bool> approveTimeRequest(String id) =>
      _resolveTimeRequest(id, 'approve');

  /// `POST /api/time-requests/{id}/deny`. Same 400-means-already-resolved shape.
  Future<bool> denyTimeRequest(String id) => _resolveTimeRequest(id, 'deny');

  Future<bool> _resolveTimeRequest(String id, String verb) async {
    final (response, _) = await _send(
      'POST',
      '/api/time-requests/${Uri.encodeComponent(id)}/$verb',
    );
    if (response.statusCode == HttpStatus.badRequest) return false;
    _requireOk(response);
    return true;
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
  static String _errorFrom(String body) {
    try {
      return (jsonDecode(body) as Map<String, dynamic>)['error'] as String? ??
          '';
    } on Object {
      return '';
    }
  }

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
      await response.drain<void>();
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
      throw NestwatchException(
        NestwatchFailure.unreachable,
        'Could not reach $authority. ${e.osError?.message ?? e.message}',
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
