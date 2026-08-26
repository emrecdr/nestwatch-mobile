/// Rebuilding the pinned, signed-in client inside a background isolate.
///
/// ## The thing this file exists to prevent
///
/// `HttpOverrides._global` is a plain `static` field (`dart-sdk/lib/_http/overrides.dart`),
/// and Dart statics are **per-isolate** — isolates share no mutable state. A WorkManager
/// task runs in its own isolate, spawned from `callbackDispatcher`, which never executes
/// `main()`. So it starts with `HttpOverrides.current == null`, and a bare `HttpClient()`
/// there is an ordinary client: system trust store, no pin.
///
/// The workmanager documentation teaches exactly that shape — its "Manage Resources in
/// Background Isolates" example constructs `HttpClient()` with no overrides. Following it
/// would pin every request a parent can watch happening and leave unpinned every request
/// the app makes while they are not looking, which is the half that matters.
///
/// There is deliberately no way to get a client out of this file without the pin: it is
/// [openBackgroundSession] or nothing.
library;

import 'dart:io';

import '../api/nestwatch_api.dart';
import '../pairing/secure_identity_store.dart';
import '../pairing/server_identity.dart';
import '../pairing/session_store.dart';
import '../pinning/pinned_http_overrides.dart';

/// A pinned client and the server it belongs to, or `null` when this device is not
/// paired and signed in.
typedef BackgroundSession = ({ServerIdentity identity, NestwatchClient client});

/// Install the pin in *this* isolate and rebuild the session from secure storage.
///
/// Returns `null` — rather than throwing — when there is nothing to do: no paired
/// server, or no stored session. A background poll on an unpaired device is not an
/// error, it is a no-op.
Future<BackgroundSession?> openBackgroundSession({
  ServerIdentityStore? identities,
  SessionStore? sessions,
}) async {
  final identityStore = identities ?? const SecureServerIdentityStore();
  final identity = await identityStore.load();
  if (identity == null) return null;

  // Before any request in this isolate. Not once at startup — there was no startup.
  HttpOverrides.global = PinnedHttpOverrides(pin: identity.fingerprint);

  final sessionStore = sessions ?? const SecureSessionStore();
  final cookie = await sessionStore.load();
  if (cookie == null) return null;

  final client = NestwatchClient(identity.authority, cookie: cookie)
    ..onSessionChanged = (next) {
      // The sliding expiry re-issues the cookie at most every 5 days, and a background
      // poll is as likely to be the request that triggers it as a foreground one. Not
      // persisting it here would let the app quietly fall back to an older cookie.
      if (next == null) {
        sessionStore.clear();
      } else {
        sessionStore.save(next);
      }
    };

  return (identity: identity, client: client);
}
