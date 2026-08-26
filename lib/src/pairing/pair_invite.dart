/// Parsing the payload behind nestwatch's pairing QR.
///
/// `pair_url` (nestwatch `src/pairing.rs`) emits exactly:
///
///     https://{host}:{port}/p/{token}
///
/// and since nestwatch `e7b90b7` (PLAN.md Phase 1) it appends the certificate fingerprint
/// as a URL *fragment*:
///
///     https://192.168.1.42:8443/p/EG629F4DQDDHS44V#fp=AB:CD:...
///
/// A fragment because it is never sent to the server, so the existing browser flow --
/// where a parent's camera app opens this URL directly -- is unaffected by it.
///
/// This parser is deliberately strict. PLAN.md trap 2: `GET /p/{token}` answers `302`
/// whether pairing succeeded or failed, on purpose, so a spent token is not an oracle.
/// The client therefore cannot learn from the response that it sent a malformed token --
/// which makes *this* the only place a bad payload can produce a useful message.
library;

import '../pinning/fingerprint.dart';

/// nestwatch's `DEFAULT_PORT` (`src/config.rs`). Used only when an address arrives
/// without one, which a real QR never does -- `pair_url` always prints the port.
///
/// Worth stating why this constant exists at all: `Uri.parse` supplies the *scheme*
/// default for a portless https URL, which is 443. Accepting that silently would turn a
/// hand-typed `192.168.0.78` into a connection to the wrong port, surfacing as
/// "server unreachable" rather than "you left the port off".
const int nestwatchDefaultPort = 8443;

/// The server's own canonicalisation, mirrored (`token::normalize`, nestwatch
/// `src/token.rs`): uppercase, keep only ASCII alphanumerics. `redeem` applies this to
/// whatever it receives, so matching it here means the app judges a token by the same
/// rule the server will.
String normalizeToken(String s) => s
    .split('')
    .where((c) => RegExp(r'[0-9A-Za-z]').hasMatch(c))
    .join()
    .toUpperCase();

/// What a scanned pairing QR resolves to.
class PairInvite {
  final String host;
  final int port;

  /// Single-use, 15-minute TTL, 16 characters of Crockford base32
  /// (`0123456789ABCDEFGHJKMNPQRSTVWXYZ` — no I, L, O or U).
  ///
  /// `null` when the address was typed rather than scanned. Not a degenerate case: §5
  /// already has to handle a token that turns out to be spent — trap 3 says a parent's
  /// camera app redeems it just by opening the QR — and the answer there is the same as
  /// the answer here, fall back to password login. A typed address is simply that state
  /// arrived at earlier.
  final String? token;

  /// The server's certificate fingerprint, when the QR carried one.
  ///
  /// `null` against any nestwatch built before PLAN.md Phase 1, which is every one of
  /// them today. That is not an error: §5 says fall back to trust-on-first-use and show
  /// the fingerprint for manual comparison. It *is* the difference between verified
  /// first use and merely trusted first use, so it is recorded rather than shrugged off.
  final Fingerprint? fingerprint;

  const PairInvite({
    required this.host,
    required this.port,
    this.token,
    this.fingerprint,
  });

  /// An address a parent typed in, with no pairing token behind it.
  const PairInvite.manual({required this.host, required this.port})
    : token = null,
      fingerprint = null;

  /// True when this QR came from a server that can prove its own identity.
  bool get isVerifiable => fingerprint != null;

  String get authority => '$host:$port';

  /// `null` when there is no token to spend, which sends §5 straight to password login.
  Uri? get redeemUrl =>
      token == null ? null : Uri.parse('https://$authority/p/$token');
  Uri get sessionUrl => Uri.parse('https://$authority/session');

  /// Parse a scanned payload, or throw [PairInviteFormatException].
  static PairInvite parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const PairInviteFormatException('That QR code was empty.');
    }

    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      throw const PairInviteFormatException(
        'That QR code is not a link, so it is not a nestwatch pairing code.',
      );
    }

    // https only. A pin cannot protect a cleartext connection, and nestwatch serves
    // nothing over http -- so an http payload is either a different QR entirely or an
    // attempt to talk us out of TLS.
    if (uri.scheme != 'https') {
      throw PairInviteFormatException(
        uri.scheme.isEmpty
            ? 'That QR code is not a nestwatch pairing code.'
            : 'That link is ${uri.scheme}, not https, so it is not from nestwatch.',
      );
    }

    if (uri.host.isEmpty) {
      throw const PairInviteFormatException('That link has no address in it.');
    }

    // The path shape is the real discriminator for "is this a nestwatch pairing QR".
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments.first != 'p') {
      throw const PairInviteFormatException(
        'That is a link, but not a nestwatch pairing link — '
        'those look like https://<address>/p/<code>.',
      );
    }

    final token = normalizeToken(segments[1]);
    if (token.isEmpty) {
      throw const PairInviteFormatException(
        'That pairing link has no code in it.',
      );
    }

    return PairInvite(
      host: uri.host,
      port: uri.hasPort ? uri.port : nestwatchDefaultPort,
      token: token,
      fingerprint: _fingerprintFromFragment(uri),
    );
  }

  /// Read `#fp=…` if present.
  ///
  /// Parsed as `&`-separated `key=value` pairs so a future server can add a second
  /// fragment key without this rejecting the whole QR.
  ///
  /// A present-but-unparseable `fp` is an ERROR, not a quiet fall back to
  /// trust-on-first-use. Silently downgrading would turn a damaged scan -- much the
  /// likeliest cause -- into a weaker security posture that says nothing about itself.
  /// (An attacker able to rewrite the QR would simply delete the fragment, which is
  /// indistinguishable from a pre-Phase-1 server; that downgrade is inherent to the QR
  /// being the root of trust, and is not what this check is for.)
  static Fingerprint? _fingerprintFromFragment(Uri uri) {
    if (!uri.hasFragment || uri.fragment.isEmpty) return null;

    for (final pair in uri.fragment.split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      if (pair.substring(0, eq) != 'fp') continue;

      final value = pair.substring(eq + 1);
      try {
        return Fingerprint.parse(Uri.decodeComponent(value));
      } on FormatException catch (e) {
        throw PairInviteFormatException(
          'That pairing code carries a damaged fingerprint (${e.message}). '
          'Scan it again — if it keeps failing, run `nestwatch pair` for a fresh code.',
        );
      }
    }
    return null;
  }

  @override
  String toString() =>
      'PairInvite($authority, token=${token == null ? "none" : "${token!.length} chars"}, '
      'fingerprint=${fingerprint ?? "none"})';
}

/// A scanned payload that is not a usable nestwatch pairing invite.
class PairInviteFormatException implements Exception {
  final String message;
  const PairInviteFormatException(this.message);

  @override
  String toString() => message;
}
