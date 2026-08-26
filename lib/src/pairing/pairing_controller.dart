/// The pairing state machine from PLAN.md §5, built around traps 2-4.
///
/// Two routes into a pinned connection, and the difference between them is the whole
/// point of Phase 1:
///
///   * the QR carries `#fp=` -> the fingerprint is known *before* the first connection,
///     so the certificate is checked against a value that never travelled the network.
///     Verified first use.
///   * the QR carries no fragment (every nestwatch shipped so far) -> the fingerprint is
///     learned from the server itself, and is only worth what the parent's comparison
///     against `nestwatch fingerprint` is worth. Trust on first use.
///
/// Redeeming the token is NOT here. §9 step 3 ends at establishing trust; step 4 adds
/// login. The token is carried through so step 4 can spend it -- once, because trap 3
/// says a camera scan of the same QR already would have.
library;

import '../api/nestwatch_api.dart';
import '../pinning/fingerprint.dart';
import '../pinning/pin_mismatch_message.dart';
import '../pinning/pinned_http_overrides.dart';
import 'pair_invite.dart';
import 'server_identity.dart';

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

class PairingSucceeded extends PairingState {
  final ServerIdentity identity;
  final SessionInfo session;
  const PairingSucceeded(this.identity, this.session);
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
/// `ChangeNotifier` lives in `package:flutter/foundation.dart`, and importing it here
/// would pull the Flutter framework — and therefore `dart:ui` — into the one part of
/// this app that decides which certificates to trust. That part has to stay runnable
/// under a plain `dart run` against a live server. The listener surface below is the
/// same three methods the Flutter widget already uses, so nothing downstream changes.
class PairingController {
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void notifyListeners() {
    // Iterate a copy: a listener may remove itself while being called.
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void dispose() => _listeners.clear();

  final PinnedHttpOverrides _overrides;
  final ServerIdentityStore _store;
  final DateTime Function() _now;

  PairingState _state = const PairingIdle();
  ServerIdentity? _current;

  PairingController({
    required this._overrides,
    required this._store,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  PairingState get state => _state;

  /// The server currently paired with, if any.
  ServerIdentity? get current => _current;

  void _emit(PairingState next) {
    _state = next;
    notifyListeners();
  }

  /// Re-apply a stored pin at app start.
  ///
  /// Called before any request is made, so the process is never briefly unpinned while
  /// a previously-paired server is reachable.
  Future<void> restore() async {
    final stored = await _store.load();
    if (stored == null) return;
    _current = stored;
    _overrides.trust(stored.fingerprint);
    notifyListeners();
  }

  /// Entry point for a scanned QR payload.
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

  /// The QR told us what to expect. Pin it first, then connect: the very first
  /// handshake is already checked against a value the network never supplied.
  Future<void> _pairVerified(PairInvite invite, Fingerprint declared) async {
    _emit(const PairingBusy('Checking that PC…'));
    _overrides.trust(declared);
    try {
      final session = await fetchSession(invite.authority);
      await _settle(
        invite,
        declared,
        PinProvenance.verifiedFromQrCode,
        session,
      );
    } on NestwatchException catch (e) {
      if (e.failure == NestwatchFailure.pinMismatch) {
        final rejection = _overrides.lastRejection;
        _emit(
          rejection == null
              ? const PairingFailed(
                  'The certificate did not match, and nothing was '
                  'recorded about what was presented.',
                )
              : PairingRefused(invite, rejection, explainMismatch(rejection)),
        );
      } else {
        _emit(PairingFailed(e.message));
      }
    }
  }

  /// No fingerprint in the QR. Observe the certificate without trusting it, then stop
  /// and ask.
  ///
  /// The observation is a deliberately refused handshake: with the pin dropped, every
  /// certificate fails and the callback records what it saw. Step 2 proved on the wire
  /// that a refusal sends nothing, so this costs no exposure -- which is what makes it
  /// safe to do before the parent has approved anything.
  Future<void> _observeForFirstUse(PairInvite invite) async {
    _emit(const PairingBusy('Looking at that PC…'));
    _overrides.distrust();

    try {
      await fetchSession(invite.authority);
      // Unreachable in practice: with no pin, every certificate is refused.
      _emit(
        const PairingFailed(
          'That PC was reached without its certificate being checked. '
          'This build refuses to continue rather than guess why.',
        ),
      );
    } on NestwatchException catch (e) {
      if (e.failure != NestwatchFailure.pinMismatch) {
        _emit(PairingFailed(e.message));
        return;
      }
      final observed = _overrides.lastRejection?.observed;
      if (observed == null) {
        _emit(const PairingFailed('Could not read that PC\'s certificate.'));
        return;
      }
      _emit(PairingNeedsFingerprintCheck(invite, observed));
    }
  }

  /// The parent has compared the shown fingerprint against `nestwatch fingerprint` on
  /// the PC and says it matches.
  Future<void> confirmFirstUse() async {
    final pending = _state;
    if (pending is! PairingNeedsFingerprintCheck) return;

    _emit(const PairingBusy('Connecting…'));
    _overrides.trust(pending.observed);
    try {
      final session = await fetchSession(pending.invite.authority);
      await _settle(
        pending.invite,
        pending.observed,
        PinProvenance.trustedOnFirstUse,
        session,
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
        'Not connected. If the fingerprint on that PC is different from the one shown, '
        'do not trust this connection — something on the network may be answering for '
        'it. Run `nestwatch fingerprint` on the PC and compare again.',
      ),
    );
  }

  /// Forget the paired server and drop the pin.
  Future<void> unpair() async {
    await _store.clear();
    _current = null;
    _overrides.distrust();
    _emit(const PairingIdle());
  }

  void reset() => _emit(const PairingIdle());

  Future<void> _settle(
    PairInvite invite,
    Fingerprint fingerprint,
    PinProvenance provenance,
    SessionInfo session,
  ) async {
    final identity = ServerIdentity(
      host: invite.host,
      port: invite.port,
      fingerprint: fingerprint,
      provenance: provenance,
      pairedAt: _now(),
    );
    await _store.save(identity);
    _current = identity;
    _emit(PairingSucceeded(identity, session));
  }
}
