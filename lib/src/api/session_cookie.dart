/// The `hh_session` cookie, and why so little of it is kept.
///
/// nestwatch sets it as (verified on the wire against 0.3.0):
///
///     hh_session=<opaque>; HttpOnly; SameSite=Strict; Secure; Path=/; Max-Age=2592000
///
/// matching `SessionManagerLayer` in nestwatch `src/server.rs` — `with_secure(true)`,
/// `with_http_only(true)`, `SameSite::Strict`, `Expiry::OnInactivity(30 days)`.
///
/// ## Only the value is kept
///
/// Every attribute above is an instruction *from* the server *to* a browser: do not
/// expose this to script, do not send it cross-site, do not send it in the clear, expire
/// it after 30 idle days. None of them are echoed back — a `Cookie:` request header
/// carries name and value and nothing else. Persisting the rest would be storing a copy
/// of the server's own policy and inviting it to drift.
///
/// Confirmed by experiment rather than assumed: a request carrying nothing but
/// `Cookie: hh_session=<value>` is answered `{"authenticated":true}`.
library;

import 'dart:io';

/// A session cookie, reduced to what actually travels.
class SessionCookie {
  /// Fixed by `with_name("hh_session")` in nestwatch `src/server.rs`.
  static const String name = 'hh_session';

  final String value;

  const SessionCookie(this.value);

  /// Pick `hh_session` out of a response's `Set-Cookie` headers, if it set one.
  ///
  /// Returns `null` when the response did not set it, which is the common case: a
  /// cookie is issued at login and at pairing, and re-issued when the sliding expiry is
  /// refreshed (at most every 5 days — `SLIDING_REFRESH_SECS` in nestwatch `src/auth.rs`),
  /// but not on an ordinary request.
  static SessionCookie? fromResponse(HttpClientResponse response) {
    for (final cookie in response.cookies) {
      if (cookie.name != name) continue;
      // A deletion: the server clearing the session (logout, or an invalidated one).
      if (cookie.value.isEmpty || cookie.maxAge == 0) return null;
      return SessionCookie(cookie.value);
    }
    return null;
  }

  /// Did this response explicitly clear the session?
  ///
  /// Distinct from "did not set one" — this is the server saying the session is over,
  /// and the stored copy has to go with it.
  static bool clearsSession(HttpClientResponse response) => response.cookies
      .any((c) => c.name == name && (c.value.isEmpty || c.maxAge == 0));

  Cookie toCookie() => Cookie(name, value);

  @override
  bool operator ==(Object other) =>
      other is SessionCookie && other.value == value;

  @override
  int get hashCode => value.hashCode;

  /// Never print the value: it is a bearer token for the whole dashboard.
  @override
  String toString() => 'SessionCookie(${value.length} chars, redacted)';
}
