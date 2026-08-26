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
import 'session_cookie.dart';

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
    if (SessionCookie.clearsSession(response)) {
      _adopt(null);
      return;
    }
    final issued = SessionCookie.fromResponse(response);
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
    if (response.statusCode != HttpStatus.ok) {
      throw NestwatchException(
        NestwatchFailure.unexpectedResponse,
        'That PC answered with HTTP ${response.statusCode}.',
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
        throw const NestwatchException(
          NestwatchFailure.rateLimited,
          'Too many wrong attempts. That PC has stopped accepting tries for a minute — '
          'wait, then try again.',
        );
      default:
        throw NestwatchException(
          NestwatchFailure.unexpectedResponse,
          'That PC answered with HTTP ${response.statusCode}.',
        );
    }
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

  /// `GET /api/usage/today`.
  Future<UsageToday> usageToday() async {
    final (response, body) = await _send('GET', '/api/usage/today');
    _requireOk(response);
    return UsageToday.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// `GET /api/screenshot?tier=preview` → JPEG bytes.
  ///
  /// **The tier is spelled out here and nowhere else**, because forgetting it is trap 4
  /// and the failure is silent. `ShotTier::from_arg` is `Some("preview") => Preview,
  /// _ => Full` (nestwatch `src/control/mod.rs`), so an omitted parameter does not error
  /// — it quietly returns the expensive tier. Measured against the fake backend: 62,795
  /// bytes at 1280x720 without it against 21,985 at 960x540 with it, and on a real 4K
  /// desktop the gap is the "20 MB a frame" recent work removed.
  ///
  /// Worse than the bytes is the audit log. A Full capture records `screenshot_taken`
  /// one-for-one — it is meant to be a deliberate human act — while Preview frames
  /// coalesce into a single `live_view` entry, "because a per-frame line evicts the
  /// entire security history in about 57 hours of live viewing". A viewer that omitted
  /// the parameter would destroy the record of every login, kill and shutdown.
  ///
  /// There is deliberately no `tier` parameter on this method and no Full equivalent:
  /// the app has no reason to ask for one, and an argument with a default is exactly how
  /// the wrong tier gets sent.
  Future<Uint8List> screenshotPreview() async {
    try {
      final request = await _client
          .getUrl(Uri.parse('https://$authority/api/screenshot?tier=preview'))
          .timeout(timeout);
      final held = _cookie;
      if (held != null) request.cookies.add(held.toCookie());

      final response = await request.close().timeout(timeout);
      _adoptFrom(response);
      _requireOk(response);

      final chunks = await response.toList();
      return Uint8List.fromList(chunks.expand((c) => c).toList());
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

  /// Every `/api/*` path is behind `require_auth`, which answers 401 once the session
  /// lapses. §5 is explicit about what that means: re-prompt for the password, do NOT
  /// re-pair — the certificate is still trusted, only the session went.
  void _requireOk(HttpClientResponse response) {
    if (response.statusCode == HttpStatus.ok) return;
    if (response.statusCode == HttpStatus.unauthorized) {
      throw const NestwatchException(
        NestwatchFailure.sessionExpired,
        'That sign-in expired.',
      );
    }
    throw NestwatchException(
      NestwatchFailure.unexpectedResponse,
      'That PC answered with HTTP ${response.statusCode}.',
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

  /// One request: attach the session, send, capture any session change.
  Future<(HttpClientResponse, String)> _send(
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    bool followRedirects = true,
  }) async {
    try {
      final request = await _client
          .openUrl(method, Uri.parse('https://$authority$path'))
          .timeout(timeout);
      request.followRedirects = followRedirects;

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

      final body = await response.transform(utf8.decoder).join();
      return (response, body);
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
}
