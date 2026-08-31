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
import 'secure_seen_requests.dart';
import '../pairing/server_identity.dart';
import '../pairing/session_store.dart';
import '../pinning/pinned_http_overrides.dart';
import 'notifications.dart';
import 'poll_logic.dart';

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
  //
  // **Unless one is already installed, which means this is not a fresh isolate.** A
  // notification action handled while the app is alive runs in the UI isolate, where
  // `PairingController` holds the very instance `main` installed — so replacing the
  // global here would leave `trust()` and `distrust()` acting on an object nothing
  // consults, and a parent pressing "Forget this PC" would not drop the pin from the
  // client actually making requests.
  //
  // Reusing what is there is also the more conservative read: in the UI isolate the
  // app's own overrides are the authority on what is trusted, and this function's job
  // is to make sure *something* pins, not to be the one that does.
  if (HttpOverrides.current is! PinnedHttpOverrides) {
    HttpOverrides.global = PinnedHttpOverrides(pin: identity.fingerprint);
  }

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

/// Open a session and poll it — which is the whole of what both notification tiers do.
///
/// Returns false when there is nothing to poll: unpaired, or signed out. The two callers
/// want different things from that, which is why it is reported rather than handled here.
/// The fifteen-minute round treats it as an ordinary quiet result; the foreground service
/// stops itself, rather than leave a persistent notification claiming to watch nothing.
///
/// The wiring below is the point. Written out per tier, the store, the notifier and the
/// canceller were two places to keep in step and one to forget — and the tier that
/// forgot would go on polling while announcing nothing.
Future<bool> pollPairedServer() async {
  final session = await openBackgroundSession();
  if (session == null) return false;
  try {
    await pollOnce(
      client: session.client,
      store: const SecureSeenRequestStore(),
      notify: notifyTimeRequests,
      cancel: cancelForRequest,
    );
    return true;
  } finally {
    // This client is built fresh for one poll and nothing outlives it, so the pooled
    // connection it leaves behind is held open for the full 30-second idleTimeout for
    // nobody. Predates the extraction — background_poll did not close it either — but
    // there is now one place to say so.
    //
    // In the foreground tier that is a socket on the phone and a TLS session on that PC
    // every sixty seconds, kept alive after the only caller has gone.
    session.client.close();
  }
}
