/// The pairing and sign-in state machine from PLAN.md §5, built around traps 2-4.
///
/// Two routes into a pinned connection, and the difference between them is the whole
/// point of Phase 1:
///
///   * the QR carries `#fp=` -> the fingerprint is known *before* the first connection,
///     so the certificate is checked against a value that never travelled the network.
///     Verified first use.
///   * the QR carries no fragment (every nestwatch shipped so far) -> the fingerprint is
///     learned from the server itself, and is worth only what the parent's comparison
///     against `nestwatch fingerprint` was worth. Trust on first use.
///
/// Once pinned, the session is established by §5 step 3: redeem the token, then ask
/// `/session` whether it worked, because trap 2 means the redemption itself cannot say.
library;

import '../api/nestwatch_api.dart';
import '../api/session_cookie.dart';
import '../pinning/fingerprint.dart';
import '../pinning/pin_mismatch_message.dart';
import '../pinning/pinned_http_overrides.dart';
import 'pair_invite.dart';
import 'server_identity.dart';
import 'session_store.dart';

sealed class PairingState {
  const PairingState();
}

class PairingIdle extends PairingState {
  const PairingIdle();
}

class PairingBusy extends PairingState {
  final String what;
  const PairingBusy(this.what);
}

/// Trust-on-first-use has observed a certificate and will not proceed until the parent
/// confirms it. Deliberately a distinct state rather than a dialog: nothing is trusted
/// while this is on screen.
class PairingNeedsFingerprintCheck extends PairingState {
  final PairInvite invite;
  final Fingerprint observed;
  const PairingNeedsFingerprintCheck(this.invite, this.observed);
}

/// Why the app is asking for the control password.
enum PasswordPrompt {
  /// The QR had no token — a typed address, so there was never one to spend.
  noToken,

  /// The token was redeemed and `/session` still says no. Trap 3: the likeliest cause is
  /// that the parent's camera app already opened the QR, which spends it in a browser.
  /// Expiry (15 minutes) is the other.
  tokenSpentOrExpired,

  /// A stored session stopped working. §5 is explicit: re-prompt for the password, do
  /// NOT re-pair — the certificate is still trusted, only the session lapsed.
  sessionLapsed,

  /// A password was tried and rejected.
  wrongPassword,

  /// 5 wrong tries inside 60 seconds (`LoginLimiter::default`, nestwatch `src/auth.rs`).
  rateLimited,
}

class PairingNeedsPassword extends PairingState {
  final String authority;
  final PasswordPrompt reason;
  final String message;
  const PairingNeedsPassword(this.authority, this.reason, this.message);
}

/// Pinned *and* signed in.
class PairingConnected extends PairingState {
  final ServerIdentity identity;
  final SessionInfo session;
  const PairingConnected(this.identity, this.session);
}

/// The QR named a fingerprint and the server did not present it. This is the case the
/// fragment exists to catch, so it is never silently downgraded to a TOFU prompt.
class PairingRefused extends PairingState {
  final PairInvite invite;
  final PinRejection rejection;
  final String explanation;
  const PairingRefused(this.invite, this.rejection, this.explanation);
}

class PairingFailed extends PairingState {
  final String message;
  const PairingFailed(this.message);
}

/// Deliberately not a `ChangeNotifier`.
///
/// `ChangeNotifier` lives in `package:flutter/foundation.dart`, and importing it would
/// pull the Flutter framework — and therefore `dart:ui` — into the one part of this app
/// that decides which certificates to trust and holds the session token. That part has
/// to stay runnable under a plain `dart run` against a live server. The listener surface
/// below is the same three methods the Flutter widget already uses.
class PairingController {
  final PinnedHttpOverrides _overrides;
  final ServerIdentityStore _identities;
  final SessionStore _sessions;
  final DateTime Function() _now;

  PairingState _state = const PairingIdle();
  ServerIdentity? _current;
  NestwatchClient? _client;

  final List<void Function()> _listeners = [];

  PairingController({
    required this._overrides,
    required this._identities,
    required this._sessions,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void notifyListeners() {
    // Iterate a copy: a listener may remove itself while being called.
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void dispose() {
    _listeners.clear();
    _client?.close();
    _client = null;
  }

  PairingState get state => _state;
  ServerIdentity? get current => _current;
  NestwatchClient? get client => _client;

  void _emit(PairingState next) {
    _state = next;
    notifyListeners();
  }

  /// Build a client for `authority`, wired so every session change is persisted.
  ///
  /// The cookie can be re-issued mid-conversation — `session.cycle_id()` rotates it on
  /// login and on pairing, and the 30-day sliding expiry refreshes it at most every 5
  /// days (`SLIDING_REFRESH_SECS`, nestwatch `src/auth.rs`). Persisting only at login
  /// would leave a stale value behind after either.
  NestwatchClient _clientFor(String authority, {SessionCookie? cookie}) {
    // Close the previous one first. Its pooled connections were established under
    // whatever certificate was pinned at the time, and re-pairing does not reach back
    // into a live pool — a kept-alive socket would carry the next request to the server
    // this app has just stopped trusting.
    _client?.close();

    final client = NestwatchClient(authority, cookie: cookie)
      ..onSessionChanged = (next) {
        if (next == null) {
          _sessions.clear();
        } else {
          _sessions.save(next);
        }
      };
    _client = client;
    return client;
  }

  // ------------------------------------------------------------------ startup

  /// Re-apply a stored pin and session at app start.
  ///
  /// Called before any request is made, so the process is never briefly unpinned while a
  /// previously-paired server is reachable.
  Future<void> restore() async {
    final stored = await _identities.load();
    if (stored == null) return;

    _current = stored;
    _overrides.trust(stored.fingerprint);

    final cookie = await _sessions.load();
    final client = _clientFor(stored.authority, cookie: cookie);

    if (cookie == null) {
      _emit(
        PairingNeedsPassword(
          stored.authority,
          PasswordPrompt.sessionLapsed,
          'Sign in to ${stored.authority}.',
        ),
      );
      return;
    }

    try {
      final session = await client.session();
      if (session.authenticated) {
        _emit(PairingConnected(stored, session));
      } else {
        // The certificate is still trusted; only the session went. §5: prompt for the
        // password, do not re-pair.
        await _sessions.clear();
        _emit(
          PairingNeedsPassword(
            stored.authority,
            PasswordPrompt.sessionLapsed,
            'That sign-in expired. Enter the control password again — the PC itself is '
            'still trusted, so there is no need to re-scan anything.',
          ),
        );
      }
    } on NestwatchException catch (e) {
      // Unreachable at launch is ordinary: the phone may be off the home network.
      _emit(PairingFailed(e.message));
    }
  }

  // ------------------------------------------------------------------ pairing

  Future<void> beginFromQrPayload(String payload) async {
    final PairInvite invite;
    try {
      invite = PairInvite.parse(payload);
    } on PairInviteFormatException catch (e) {
      _emit(PairingFailed(e.message));
      return;
    }
    await begin(invite);
  }

  Future<void> begin(PairInvite invite) async {
    final declared = invite.fingerprint;
    if (declared != null) {
      await _pairVerified(invite, declared);
    } else {
      await _observeForFirstUse(invite);
    }
  }

  /// The QR told us what to expect. Pin it first, then connect: the very first handshake
  /// is already checked against a value the network never supplied.
  Future<void> _pairVerified(PairInvite invite, Fingerprint declared) async {
    _emit(const PairingBusy('Checking that PC…'));
    _overrides.trust(declared);
    try {
      await _establishSession(
        invite,
        declared,
        PinProvenance.verifiedFromQrCode,
      );
    } on NestwatchException catch (e) {
      if (e.failure == NestwatchFailure.pinMismatch) {
        // Ask about the authority we were actually talking to, not "the last one".
        final rejection = _overrides.rejectionFor(invite.authority);
        _emit(
          rejection == null
              ? const PairingFailed(
                  'The certificate did not match, and nothing was recorded about what '
                  'was presented.',
                )
              : PairingRefused(invite, rejection, explainMismatch(rejection)),
        );
      } else {
        _emit(PairingFailed(e.message));
      }
    }
  }

  /// No fingerprint in the QR. Observe the certificate without trusting it, then stop and
  /// ask.
  ///
  /// The observation is a deliberately refused handshake: with the pin dropped, every
  /// certificate fails and the callback records what it saw. Step 2 proved on the wire
  /// that a refusal sends nothing, so this costs no exposure — which is what makes it
  /// safe to do before the parent has approved anything.
  Future<void> _observeForFirstUse(PairInvite invite) async {
    _emit(const PairingBusy('Looking at that PC…'));
    _overrides.distrust();

    try {
      await _clientFor(invite.authority).session();
      // Unreachable in practice: with no pin, every certificate is refused.
      _emit(
        const PairingFailed(
          'That PC was reached without its certificate being checked. This build refuses '
          'to continue rather than guess why.',
        ),
      );
    } on NestwatchException catch (e) {
      if (e.failure != NestwatchFailure.pinMismatch) {
        _emit(PairingFailed(e.message));
        return;
      }
      final observed = _overrides.rejectionFor(invite.authority)?.observed;
      if (observed == null) {
        _emit(const PairingFailed("Could not read that PC's certificate."));
        return;
      }
      _emit(PairingNeedsFingerprintCheck(invite, observed));
    }
  }

  /// The parent has compared the shown fingerprint against `nestwatch fingerprint` on the
  /// PC and says it matches.
  Future<void> confirmFirstUse() async {
    final pending = _state;
    if (pending is! PairingNeedsFingerprintCheck) return;

    _emit(const PairingBusy('Connecting…'));
    _overrides.trust(pending.observed);
    try {
      await _establishSession(
        pending.invite,
        pending.observed,
        PinProvenance.trustedOnFirstUse,
      );
    } on NestwatchException catch (e) {
      // The certificate changed between observing it and trusting it. Rare, and worth
      // saying rather than retrying.
      _overrides.distrust();
      _emit(PairingFailed(e.message));
    }
  }

  /// The parent says the fingerprint does not match what the PC printed.
  void rejectFirstUse() {
    _overrides.distrust();
    _emit(
      const PairingFailed(
        'Not connected. If the fingerprint on that PC is different from the one shown, do '
        'not trust this connection — something on the network may be answering for it. '
        'Run `nestwatch fingerprint` on the PC and compare again.',
      ),
    );
  }

  // ------------------------------------------------------------------ session

  /// §5 step 3, once the pin is settled.
  ///
  /// Redeem the token, then ask `/session` whether that worked — because trap 2 means the
  /// redemption's own response cannot say. `auth::pair` ends at `Redirect::to("/")` on
  /// every path, success and failure alike, so that a guessed token is not an oracle.
  ///
  /// A token that fails is not an error. Trap 3: the instruction printed under the QR
  /// tells the parent to scan it with their camera, which opens it in a browser and
  /// spends it. Reaching this app with an already-spent token is the *expected* case, and
  /// the answer is the password prompt, not a dead end.
  Future<void> _establishSession(
    PairInvite invite,
    Fingerprint fingerprint,
    PinProvenance provenance,
  ) async {
    final client = _clientFor(invite.authority);

    // Probe first: unauthenticated, LAN-gated, and it settles the pin before a token is
    // spent on a server that might not be the right one.
    var session = await client.session();

    final token = invite.token;
    if (token != null && !session.authenticated) {
      await client.redeemPairingToken(token);
      session = await client.session();
    }

    final identity = await _persistIdentity(invite, fingerprint, provenance);

    if (session.authenticated) {
      _emit(PairingConnected(identity, session));
      return;
    }

    _emit(
      PairingNeedsPassword(
        invite.authority,
        token == null
            ? PasswordPrompt.noToken
            : PasswordPrompt.tokenSpentOrExpired,
        token == null
            ? 'Enter the control password for ${invite.authority}.'
            : 'That pairing code had already been used — most likely by opening the QR '
                  'with your phone\'s camera, which signs in the browser instead. Enter '
                  'the control password instead; the PC itself is now trusted either way.',
      ),
    );
  }

  /// Try the control password.
  Future<void> submitPassword(String password) async {
    final pending = _state;
    if (pending is! PairingNeedsPassword) return;

    final client = _client ?? _clientFor(pending.authority);
    _emit(const PairingBusy('Signing in…'));

    try {
      await client.login(password);
      final session = await client.session();
      final identity = _current;
      if (identity == null) {
        _emit(const PairingFailed('Signed in, but no paired PC is on record.'));
        return;
      }
      _emit(PairingConnected(identity, session));
    } on NestwatchException catch (e) {
      final reason = switch (e.failure) {
        NestwatchFailure.badPassword => PasswordPrompt.wrongPassword,
        NestwatchFailure.rateLimited => PasswordPrompt.rateLimited,
        _ => null,
      };
      if (reason == null) {
        _emit(PairingFailed(e.message));
        return;
      }
      _emit(PairingNeedsPassword(pending.authority, reason, e.message));
    }
  }

  /// Drop the session but keep the pin — signing out is not un-pairing.
  Future<void> signOut() async {
    await _sessions.clear();
    final identity = _current;
    _client?.close();
    _client = null;
    if (identity == null) {
      _emit(const PairingIdle());
      return;
    }
    _clientFor(identity.authority);
    _emit(
      PairingNeedsPassword(
        identity.authority,
        PasswordPrompt.sessionLapsed,
        'Sign in to ${identity.authority}.',
      ),
    );
  }

  /// Forget the paired server: drop the pin and the session together.
  Future<void> unpair() async {
    await _sessions.clear();
    await _identities.clear();
    _current = null;
    _client?.close();
    _client = null;
    _overrides.distrust();
    _emit(const PairingIdle());
  }

  void reset() => _emit(const PairingIdle());

  Future<ServerIdentity> _persistIdentity(
    PairInvite invite,
    Fingerprint fingerprint,
    PinProvenance provenance,
  ) async {
    final identity = ServerIdentity(
      host: invite.host,
      port: invite.port,
      fingerprint: fingerprint,
      provenance: provenance,
      pairedAt: _now(),
    );
    await _identities.save(identity);
    _current = identity;
    return identity;
  }
}
