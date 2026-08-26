/// The server this app has decided to trust, and how much that decision is worth.
library;

import '../pinning/fingerprint.dart';

/// Where the pinned fingerprint came from.
///
/// This is not bookkeeping. PLAN.md §5 requires the app to "say plainly that this first
/// connection is unverified" when the QR carried no fingerprint, and that statement has
/// to survive app restarts -- otherwise the warning is shown once and the weaker trust
/// silently becomes indistinguishable from the stronger one forever after.
enum PinProvenance {
  /// The QR carried `#fp=`, so the fingerprint was known *before* the first connection.
  /// The certificate was checked against a value that never travelled over the network.
  verifiedFromQrCode,

  /// The QR carried no fingerprint (any nestwatch before PLAN.md Phase 1). The
  /// fingerprint was learned from the server itself and confirmed by the parent reading
  /// it off the PC. Only as good as that comparison actually was.
  trustedOnFirstUse;

  bool get isVerified => this == PinProvenance.verifiedFromQrCode;
}

/// A server the app has paired with.
class ServerIdentity {
  final String host;
  final int port;
  final Fingerprint fingerprint;
  final PinProvenance provenance;
  final DateTime pairedAt;

  const ServerIdentity({
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.provenance,
    required this.pairedAt,
  });

  String get authority => '$host:$port';

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'fingerprint': fingerprint.toString(),
    'provenance': provenance.name,
    'pairedAt': pairedAt.toUtc().toIso8601String(),
  };

  static ServerIdentity fromJson(Map<String, dynamic> json) => ServerIdentity(
    host: json['host'] as String,
    port: json['port'] as int,
    fingerprint: Fingerprint.parse(json['fingerprint'] as String),
    provenance: PinProvenance.values.firstWhere(
      (p) => p.name == json['provenance'],
      // An unrecognised provenance must read as the weaker of the two. Anything else
      // would let a storage-format change quietly promote trust-on-first-use to
      // verified.
      orElse: () => PinProvenance.trustedOnFirstUse,
    ),
    pairedAt: DateTime.parse(json['pairedAt'] as String),
  );
}

/// Persists the paired server across app launches.
///
/// Abstract on purpose. The implementation that matters is Keystore-backed
/// (`SecureServerIdentityStore`), but that reaches `flutter_secure_storage` and so drags
/// in the whole Flutter framework — which would make the pairing state machine above
/// impossible to exercise without a device or an emulator. The decision about *what to
/// trust* is the security-critical part of this app; keeping it free of Flutter is what
/// lets `tool/prove_tofu.dart` run it against a live server on every change.
abstract class ServerIdentityStore {
  Future<ServerIdentity?> load();
  Future<void> save(ServerIdentity identity);
  Future<void> clear();
}

/// An in-memory [ServerIdentityStore], for tests and for the live proof harnesses.
///
/// `flutter_secure_storage` talks over a platform channel, so the real store cannot run
/// under `dart run` or in a plain `flutter test`. Substituting here keeps the pairing
/// logic itself exercisable without a device.
class InMemoryServerIdentityStore implements ServerIdentityStore {
  ServerIdentity? _held;

  @override
  Future<ServerIdentity?> load() async => _held;

  @override
  Future<void> save(ServerIdentity identity) async => _held = identity;

  @override
  Future<void> clear() async => _held = null;
}
