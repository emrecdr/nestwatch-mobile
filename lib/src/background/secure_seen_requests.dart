/// The Keystore-backed [SeenRequestStore].
///
/// ## Why it lives here, in its own file
///
/// It used to sit in `pairing/secure_identity_store.dart` beside the identity and session
/// stores, grouped because all three use `flutter_secure_storage`. That is grouping by
/// *technology*, and it cost more than tidiness: that file then had to import
/// `background/seen_requests.dart` for the interface, closing a dependency cycle between
/// the two layers — four edges one way and one back. Two of this class's three callers
/// were already in `background/`.
///
/// Separate from `seen_requests.dart` rather than appended to it, for the same reason
/// `pairing/` splits its own stores: that file is deliberately Flutter-free and
/// `pairing_controller.dart` imports it. Putting `flutter_secure_storage` there would put
/// Flutter inside the part of this app that must run under a plain `dart run` — which is
/// precisely the mistake that stopped four harnesses compiling one commit ago.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'seen_requests.dart';

/// Keystore-backed [SeenRequestStore].
class SecureSeenRequestStore implements SeenRequestStore {
  static const _key = 'nestwatch.seen_requests.v1';
  static const _separator = ',';

  /// The server caps the queue at 5, so this can never grow unboundedly — but it is
  /// pruned to what is currently pending on every poll anyway, so a resolved request
  /// cannot keep a slot forever.
  final FlutterSecureStorage _storage;

  const SecureSeenRequestStore({this._storage = const FlutterSecureStorage()});

  @override
  Future<Set<String>> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return {};
    return raw.split(_separator).where((s) => s.isNotEmpty).toSet();
  }

  @override
  Future<void> save(Set<String> ids) =>
      _storage.write(key: _key, value: ids.join(_separator));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
