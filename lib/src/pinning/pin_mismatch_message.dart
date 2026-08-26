/// Turning a refused handshake into something a parent can act on.
///
/// PLAN.md §5 is specific about this, and it is the one place where the pin stops being
/// a cryptographic problem and becomes a human one:
///
/// > On **pin mismatch**, say which of the two things happened: *"This PC's certificate
/// > changed. If you just re-ran `nestwatch install`, re-scan the QR. If you didn't,
/// > something on your network may be impersonating it."* Both are real, and only the
/// > parent can tell them apart.
///
/// ## What the evidence can and cannot settle
///
/// The tempting signal is [PinRejection.certAge] -- how old the presented certificate
/// was when it was refused. `cert::generate` mints a fresh key and certificate, so a
/// reinstall that *reissues* presents a young one.
///
/// Most reinstalls do not reissue at all. `src/install.rs` computes
/// `reuse = !force_new && covered && cert.exists() && key.exists()` and keeps the
/// existing certificate while it still covers the current addresses -- "Devices you've
/// already paired won't warn again." A new certificate follows only from `--new-cert`, a
/// changed address, or a missing file. So this screen is rarer than it looks, and the
/// copy must not tell a parent that installing always reissues. (PLAN §3 says "`install`
/// rotates both"; that is the half of the claim which does not hold.)
///
/// **That does not work in the direction it first appears to.** An impostor also mints
/// its own certificate, so its certificate is young too -- and nestwatch backdates
/// `not_before` by exactly one hour (`src/cert.rs`, for clock skew), which an attacker
/// can copy trivially. Youth is therefore consistent with *both* stories and settles
/// neither.
///
/// The inference that does hold runs the other way. A certificate far older than a
/// recent `install` could have produced is *inconsistent* with the reinstall story,
/// whoever is presenting it. That rules a story out rather than ruling one in, which is
/// the only honest direction available here.
///
/// So this is a filter for **accidents** -- the wrong PC on the LAN, an old machine
/// still running a stale install -- not a defence against a competent attacker. The
/// defence against an attacker is the parent comparing the fingerprint against
/// `nestwatch fingerprint` on the PC itself. Nothing here replaces that, and the copy
/// must not imply otherwise.
library;

import 'pinned_http_overrides.dart';

/// How long after its `not_before` a certificate can still be explained by "I just
/// re-ran install".
///
/// Generous on purpose. nestwatch backdates `not_before` an hour, and a parent may
/// reinstall in the morning and open the app that evening. Being wrong in the tight
/// direction produces a false alarm on a legitimate reinstall, which is the cheaper of
/// the two errors but still erodes a warning that needs to be believed when it fires.
const Duration reinstallPlausibleWindow = Duration(hours: 24);

/// What the evidence supports. The names carry the epistemics deliberately:
/// "consistent with" is not "probably", and nothing here says "verified".
enum MismatchStory {
  /// The certificate is young enough that a recent `nestwatch install` explains it.
  /// An impostor's freshly minted certificate looks identical, so this narrows nothing
  /// on its own -- it only means the reinstall story has not been excluded.
  consistentWithReinstall,

  /// The certificate is too old for a recent `install` to have produced it. Something
  /// other than a reinstall is going on: a different machine, or an old one.
  inconsistentWithReinstall,

  /// No usable timing information.
  unknown,
}

/// Classify a refusal against the only evidence available at the handshake.
MismatchStory classifyMismatch(PinRejection rejection) {
  final age = rejection.certAge;

  // A negative age means the certificate claims to start in the future -- clock skew in
  // one direction or the other, and not something to reason about.
  if (age.isNegative) return MismatchStory.unknown;

  return age <= reinstallPlausibleWindow
      ? MismatchStory.consistentWithReinstall
      : MismatchStory.inconsistentWithReinstall;
}

/// The parent-facing explanation.
///
/// Leads with the action in both cases, and never claims to know which story is true.
String explainMismatch(PinRejection rejection) {
  final story = classifyMismatch(rejection);
  final buffer = StringBuffer()
    ..writeln(
      '${rejection.host} presented a different certificate than the one '
      'this app trusts, so the connection was refused before anything was sent.',
    )
    ..writeln();

  switch (story) {
    case MismatchStory.consistentWithReinstall:
      // Deliberately does NOT lead with the reassuring cause. Certificates change
      // rarely: `install` reuses the existing one while its addresses still cover the
      // PC, and nestwatch says why — reissuing on every routine upgrade "trains the
      // parent to click through warnings without looking, the exact habit the
      // fingerprint check depends on them not having". So the innocent explanations are
      // narrow, and naming them first would tilt a parent toward the comfortable one at
      // the moment that costs most.
      buffer
        ..writeln(
          'Certificates do not normally change. Two ordinary things cause it: you ran '
          '`nestwatch install --new-cert`, or that PC\'s address on your network '
          'changed. Nothing else should.',
        )
        ..writeln()
        ..writeln(
          'Run `nestwatch fingerprint` on the PC itself and compare it with the value '
          'below. Only trust this connection if they match — and do not re-scan a QR '
          'to make the warning go away.',
        );
    case MismatchStory.inconsistentWithReinstall:
      buffer
        ..writeln(
          'This certificate is too old to have come from a recent '
          '`nestwatch install`, so a reinstall does not explain it.',
        )
        ..writeln()
        ..writeln(
          'You may be pointed at a different PC than the one you paired with. Run '
          '`nestwatch fingerprint` on the PC you mean to reach and compare it with the '
          'value below before trusting anything.',
        );
    case MismatchStory.unknown:
      buffer.writeln(
        'Check the fingerprint below against `nestwatch fingerprint` run '
        'on the PC itself before you trust it.',
      );
  }

  return buffer.toString().trimRight();
}
