/// Certificate pinning for every `dart:io` socket in the process.
///
/// ## Why an [HttpOverrides] and not a hand-rolled client
///
/// `Image.network` builds its own `HttpClient` from a lazily-initialised private static
/// and accepts no injection outside `assert`s. That would normally make the screenshot
/// screen impossible to pin. It does not, because Dart's `HttpClient` **factory
/// constructor** consults `HttpOverrides.current` before constructing anything:
///
/// ```dart
/// factory HttpClient({SecurityContext? context}) {
///   HttpOverrides? overrides = HttpOverrides.current;
///   if (overrides == null) return _HttpClient(context);
///   return overrides.createHttpClient(context);
/// }
/// ```
///
/// So installing this as [HttpOverrides.global] at the top of `main()` — before that
/// static is ever touched — pins `Image.network` and every other `dart:io` consumer.
///
/// The corollary is the project's one dependency rule: **no package may bypass
/// `dart:io`'s `HttpClient`**. `cupertino_http` and `cronet_http` hand off to the
/// platform's native stack, which never enters Dart's client, so this override never
/// sees their traffic and it leaves the device unpinned. Audit on every `pub add`.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import 'fingerprint.dart';

/// What was seen on the wire when a handshake was refused.
///
/// [HttpClient.badCertificateCallback] returns a bare `bool`; Dart converts a `false`
/// into a generic `HandshakeException` that carries none of this. So the callback has
/// to record its evidence as a side effect, or the UI has nothing to explain with.
class PinRejection {
  final String host;
  final int port;

  /// The fingerprint actually presented. This is the value a parent can compare by eye
  /// against `nestwatch fingerprint` run on the PC itself.
  final Fingerprint observed;

  /// The pin we were holding at the time, if any.
  final Fingerprint? expected;

  /// When the presented certificate became valid. `cert::generate` mints a fresh
  /// key and cert on every `nestwatch install`, so this is effectively "when install
  /// was last run" — which is the fact that separates the two stories below.
  final DateTime notBefore;

  /// When the refusal happened.
  final DateTime at;

  const PinRejection({
    required this.host,
    required this.port,
    required this.observed,
    required this.expected,
    required this.notBefore,
    required this.at,
  });

  /// How old the presented certificate was at the moment we refused it.
  Duration get certAge => at.difference(notBefore);
}

/// Installs a pin over every `dart:io` HTTP client in the process.
///
/// The pin is mutable so re-pairing can swap it in place: [HttpOverrides.global] is set
/// once, in `main()`, and clients are built lazily per request.
class PinnedHttpOverrides extends HttpOverrides {
  Fingerprint? _pin;

  /// Refusals, keyed by `host:port`.
  ///
  /// Deliberately not a single "most recent" field, which is what this was. Dart is
  /// single-threaded per isolate, but `badCertificateCallback` still interleaves with
  /// everything else: request A's handshake fails and records, request B's handshake
  /// fails and overwrites, and then A's `catch` reads B's value. The caller has already
  /// returned from the callback by the time it looks.
  ///
  /// That is not a cosmetic race. What gets read is the fingerprint shown to a parent as
  /// "this is what the PC presented, compare it against `nestwatch fingerprint`" — so
  /// the failure mode is telling them to compare against the *wrong server's*
  /// certificate, at the exact moment the app is asking them to make a security
  /// decision. A wrong fingerprint there is worse than none.
  ///
  /// Keyed lookup removes the question: every caller already knows which authority it
  /// was talking to.
  final Map<String, PinRejection> _rejections = {};

  PinnedHttpOverrides({Fingerprint? pin})
    : _pin = pin; // ignore: prefer_initializing_formals

  Fingerprint? get pin => _pin;

  /// Swap the pinned certificate — after pairing, or after the parent confirms a
  /// deliberate re-install.
  void trust(Fingerprint fingerprint) {
    _pin = fingerprint;
    _rejections.clear();
  }

  /// Drop the pin, so the next handshake is refused and the certificate it presented is
  /// recorded in [lastRejection].
  ///
  /// This is how trust-on-first-use *observes* a server without trusting it: with no pin
  /// set, `_verify` refuses everything, and refusing is what captures the fingerprint.
  /// Nothing is sent during a refused handshake, so the observation costs no exposure —
  /// which is precisely the property step 2 proved on the wire.
  void distrust() {
    _pin = null;
    _rejections.clear();
  }

  /// What `authority` (`host:port`) presented when it was last refused, if it was.
  PinRejection? rejectionFor(String authority) => _rejections[authority];

  /// Every refusal recorded since the last pin change. For diagnostics only — the UI
  /// asks about one authority at a time.
  Map<String, PinRejection> get rejections => Map.unmodifiable(_rejections);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // `withTrustedRoots: false` is load-bearing, not tidiness.
    //
    // `badCertificateCallback` fires only when a certificate FAILS to authenticate.
    // Leave the platform trust store in place and any certificate that validates
    // cleanly never reaches the callback at all — so anyone holding a publicly-trusted
    // certificate for this address is admitted by code that looks pinned. Emptying the
    // store makes every certificate fail, which makes the callback the sole authority.
    //
    // Note that `test/pinning_socket_test.dart` cannot prove this half: its fixtures are
    // self-signed, so they fail under either setting and the callback fires regardless.
    // Flipping this to `true` leaves that whole file green. It stays because it makes the
    // callback the sole authority by construction rather than by luck.
    //
    // A deliberate second consequence: accepting from this callback accepts the cert
    // whatever the reason it failed, hostname mismatch included. The pin therefore
    // replaces hostname verification outright — which is why this client is immune to
    // the DHCP-lease SAN breakage that makes a browser error out on the same server.
    // `super.createHttpClient` builds the real client directly. Calling the public
    // `HttpClient(...)` factory here would consult `HttpOverrides.current` -- which is
    // this object -- and recurse until the stack gives out. The same lookup that makes
    // process-wide pinning possible is the one that has to be stepped around here.
    //
    // The caller's `context` is deliberately DISCARDED rather than honoured. Passing it
    // through would let any code in the process hand us a context with the trust store
    // enabled, and a certificate that then validated cleanly would never reach
    // `_verify` at all -- the same silent admission `withTrustedRoots: false` exists to
    // prevent, one layer up. Nothing in this app is allowed to opt out of the pin.
    final client = super.createHttpClient(
      SecurityContext(withTrustedRoots: false),
    );

    client.badCertificateCallback = _verify;
    return client;
  }

  /// The comparison, inside the handshake.
  ///
  /// This has to happen here rather than after the response, because a check that runs
  /// later has already streamed the request body to whoever answered the socket. That
  /// is exactly the flaw in dio's published pinning recipe, and it is why §6 asks for
  /// the pin to be proven by refusal *before any body is sent*, not by "wrong cert ⇒
  /// error" — a late check produces that error too, having already leaked the secret.
  bool _verify(X509Certificate cert, String host, int port) {
    final observed = Fingerprint.fromBytes(sha256.convert(cert.der).bytes);
    final expected = _pin;

    if (expected != null && expected.matches(observed.bytes)) {
      return true;
    }

    _rejections['$host:$port'] = PinRejection(
      host: host,
      port: port,
      observed: observed,
      expected: expected,
      notBefore: cert.startValidity,
      at: DateTime.now(),
    );
    return false;
  }
}
