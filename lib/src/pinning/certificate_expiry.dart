/// How long the pinned certificate has left, and when to say so.
///
/// ## The asymmetry this closes
///
/// nestwatch issues certificates for 825 days and starts warning 30 days out — into the
/// service log and `doctor`, both of which live on the child's PC. The parent reads
/// neither. The phone is the surface they look at daily, and it had the answer in hand
/// and dropped it: `badCertificateCallback` receives an `X509Certificate` carrying
/// `endValidity`, and this app read only `startValidity`, for the mismatch screen.
///
/// ## Why the phone is the one that has to say it
///
/// Because the pin is the sole authority, **an expired certificate keeps working here.**
/// That is not reasoning, it is measured — `test/expiry_test.dart` stands up a server
/// presenting a certificate that expired in January 2024 and the pinned client completes
/// the request. The browser hard-fails on the same certificate.
///
/// So the failure a parent actually meets is: the dashboard breaks, the phone is fine,
/// and every instinct points at the PC being broken rather than at a certificate having
/// lapsed. The one client that still works is the only one in a position to explain.
///
/// ## Why there is no "could not check" here
///
/// Every other check in this app has three outcomes. This one has two, and the
/// difference is worth stating rather than looking like an oversight: a null expiry does
/// not mean the certificate declined to say, it means no handshake has happened *yet*.
/// It resolves itself on the first request, a second later. Rendering "could not check"
/// for a state that is about to answer itself would teach a parent to ignore the words.
library;

/// Mirrors `RENEW_WARN_DAYS` in nestwatch `src/cert.rs`.
///
/// Deliberately the same number rather than one chosen here. nestwatch's own comment says
/// that constant is `pub` so `doctor` "nags at the same threshold as the service log",
/// because "two different answers to 'is this cert about to lapse?' would have the parent
/// reading a diagnostic that contradicts the warning in their log file". A phone that
/// disagreed with both would be a third answer. `tool/check_golden.sh` compares them.
const int renewWarnDays = 30;

enum CertificateLife {
  /// More than [renewWarnDays] left. Nothing to say.
  healthy,

  /// Inside the warning window. Still working everywhere, including the browser.
  expiringSoon,

  /// Past its end date: still working *here*, and broken in the browser.
  expired,
}

class CertificateExpiry {
  final CertificateLife life;

  /// Negative once the date has passed, which is what the expired sentence counts back
  /// from. The end date itself is not kept: every sentence a parent reads is written in
  /// days, and a field nothing reads is a field that goes quietly wrong.
  final int daysLeft;

  const CertificateExpiry._(this.life, this.daysLeft);

  /// `null` when no certificate has been seen yet — see the library note above.
  static CertificateExpiry? of(DateTime? notAfter, {DateTime? now}) {
    if (notAfter == null) return null;
    final at = now ?? DateTime.now();
    final left = notAfter.difference(at).inDays;
    final life = switch (left) {
      < 0 => CertificateLife.expired,
      <= renewWarnDays => CertificateLife.expiringSoon,
      _ => CertificateLife.healthy,
    };
    return CertificateExpiry._(life, left);
  }

  bool get isWarning => life == CertificateLife.expired;

  /// `null` when there is nothing worth saying.
  ///
  /// Both sentences name the consequence rather than the date alone. "Expires in 12 days"
  /// invites a parent to do nothing for eleven of them; what they need to know is that
  /// fixing it re-pairs every device they own, which is a thing to schedule rather than
  /// discover.
  String? get message => switch (life) {
    CertificateLife.healthy => null,
    CertificateLife.expiringSoon =>
      'That PC\'s certificate expires in $daysLeft '
          '${daysLeft == 1 ? 'day' : 'days'}. This app will keep working, but the '
          'dashboard in a browser will stop. Renewing it on the PC means pairing '
          'this phone — and every other device — again, so it is worth picking the '
          'moment rather than being caught by it.',
    CertificateLife.expired =>
      'That PC\'s certificate expired ${-daysLeft} '
          '${daysLeft == -1 ? 'day' : 'days'} ago. This app still works, because it '
          'checks the fingerprint rather than the date — but the browser dashboard '
          'will refuse to open, and that is why, not because the PC is broken. '
          'Renewing it re-pairs every device.',
  };
}
