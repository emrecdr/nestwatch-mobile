/// Turning a refused handshake into something a parent can act on.
///
/// PLAN.md §5 is specific about this, and it is the one place where the pin becomes a
/// user-experience problem rather than a cryptographic one:
///
/// > On **pin mismatch**, say which of the two things happened: *"This PC's certificate
/// > changed. If you just re-ran `nestwatch install`, re-scan the QR. If you didn't,
/// > something on your network may be impersonating it."* Both are real, and only the
/// > parent can tell them apart.
///
/// The evidence available is in [PinRejection]: the fingerprint presented, the pin we
/// held, and `notBefore` -- when the presented certificate became valid. That last one
/// carries real signal, because `cert::generate` mints a brand-new key and certificate
/// on every `nestwatch install` (nestwatch `src/cert.rs`), so `notBefore` is
/// effectively "when install was last run on whatever answered this socket".
library;

import 'pinned_http_overrides.dart';

/// How the app explains a refusal.
enum MismatchStory {
  /// Consistent with the parent having just re-run `nestwatch install`.
  probablyReinstalled,

  /// Consistent with something else on the network answering for the PC.
  possiblyImpostor,

  /// The evidence does not favour either. Say so, and offer both.
  ambiguous,
}

/// Decide which story the evidence supports.
///
/// TODO(you): implement this -- see the request in the session notes.
///
/// The interesting input is [PinRejection.certAge]: how old the presented certificate
/// was at the moment it was refused. A certificate minted seconds ago is hard to square
/// with an impostor that has been sitting on the LAN; one minted last month is hard to
/// square with "you just re-ran install". Where you put the boundary -- and whether you
/// are willing to call it at all rather than returning [MismatchStory.ambiguous] -- is a
/// judgement about which way this should fail, and it is yours to make.
///
/// Worth weighing: guessing [MismatchStory.probablyReinstalled] when it was actually an
/// attacker teaches the parent to re-scan past a real warning, which is the expensive
/// mistake. Guessing [MismatchStory.possiblyImpostor] after a legitimate reinstall
/// alarms them for nothing, which is cheap but erodes the warning if it happens often.
MismatchStory classifyMismatch(PinRejection rejection) {
  // Deliberately non-committal until the call above is made: both possibilities get
  // shown, which is correct but wordier than it needs to be.
  return MismatchStory.ambiguous;
}
