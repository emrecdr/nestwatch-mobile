/// The few nestwatch endpoints this app talks to.
///
/// Only `/session` so far -- PLAN.md §9 stops the walking skeleton before the screens.
/// Every request goes through `dart:io`'s `HttpClient`, which is pinned process-wide by
/// `HttpOverrides.global`; there is deliberately no client object to configure here,
/// because a second way to make requests would be a second way to make unpinned ones.
library;

import 'dart:convert';
import 'dart:io';

/// `GET /session` -- unauthenticated and LAN-gated (nestwatch `auth::me`).
///
/// §5 picks this as the first call for three reasons at once: it needs no credentials,
/// so it can run before pairing; it is refused off-LAN by `require_lan_peer` before any
/// auth work; and it doubles as the pin probe, because reaching it at all means the
/// handshake was accepted.
class SessionInfo {
  final bool authenticated;
  final String version;

  const SessionInfo({required this.authenticated, required this.version});

  static SessionInfo fromJson(Map<String, dynamic> json) => SessionInfo(
    authenticated: json['authenticated'] as bool? ?? false,
    version: json['version'] as String? ?? 'unknown',
  );

  @override
  String toString() => 'SessionInfo(authenticated: $authenticated, $version)';
}

/// Why a request to nestwatch did not produce an answer.
enum NestwatchFailure {
  /// The handshake was refused: the certificate did not match the pin.
  pinMismatch,

  /// `require_lan_peer` answered 403 -- the phone is not on a private network as far as
  /// the PC can see. PLAN.md §6 calls this out specifically: it is what a VPN active on
  /// the phone looks like, and the message must say so rather than "server unreachable".
  notOnLan,

  /// No route, refused connection, DNS failure, timeout.
  unreachable,

  /// Reached the server, but the answer was not what this app expects.
  unexpectedResponse,
}

class NestwatchException implements Exception {
  final NestwatchFailure failure;
  final String message;
  const NestwatchException(this.failure, this.message);

  @override
  String toString() => message;
}

/// Fetch `/session` from `authority` (`host:port`).
Future<SessionInfo> fetchSession(
  String authority, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(Uri.parse('https://$authority/session'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);

    if (response.statusCode == HttpStatus.forbidden) {
      await response.drain<void>();
      throw const NestwatchException(
        NestwatchFailure.notOnLan,
        'That PC refused the connection because this phone does not look like it is '
        'on the same home network. If a VPN is switched on, turn it off — nestwatch '
        'only answers devices on the LAN.',
      );
    }

    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw NestwatchException(
        NestwatchFailure.unexpectedResponse,
        'That PC answered with HTTP ${response.statusCode}.',
      );
    }

    try {
      return SessionInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } on Object {
      throw const NestwatchException(
        NestwatchFailure.unexpectedResponse,
        'Something answered at that address, but it is not nestwatch.',
      );
    }
  } on HandshakeException {
    throw const NestwatchException(
      NestwatchFailure.pinMismatch,
      'The certificate did not match.',
    );
  } on SocketException catch (e) {
    throw NestwatchException(
      NestwatchFailure.unreachable,
      'Could not reach $authority. ${e.osError?.message ?? e.message}',
    );
  } finally {
    client.close(force: true);
  }
}
