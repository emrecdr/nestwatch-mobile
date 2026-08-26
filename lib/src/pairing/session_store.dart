/// Persisting the session cookie across app launches.
///
/// Kept apart from [ServerIdentityStore] because the two hold different kinds of thing
/// and want different handling on loss.
///
/// The **fingerprint** is public — printed on a console, read aloud — and goes into
/// secure storage for its *integrity*: an attacker who rewrites it has silently defeated
/// pinning forever. Losing it costs a re-pair.
///
/// The **session cookie** is a bearer token. Anyone holding it has the dashboard for up
/// to 30 idle days: screenshots of the child's desktop, remote shutdown, the lot. It goes
/// into secure storage for its *confidentiality*, and losing it costs only a password
/// prompt — which is the cheap direction, and why nothing here tries to recover a
/// cookie it cannot read.
library;

import '../api/session_cookie.dart';

abstract class SessionStore {
  Future<SessionCookie?> load();
  Future<void> save(SessionCookie cookie);
  Future<void> clear();
}

class InMemorySessionStore implements SessionStore {
  SessionCookie? _held;

  @override
  Future<SessionCookie?> load() async => _held;

  @override
  Future<void> save(SessionCookie cookie) async => _held = cookie;

  @override
  Future<void> clear() async => _held = null;
}
