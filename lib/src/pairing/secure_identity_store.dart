/// The Keystore-backed [ServerIdentityStore].
///
/// Split out from `server_identity.dart` so that the pairing state machine stays free of
/// Flutter — see the note on [ServerIdentityStore].
///
/// ## Why secure storage for a value that is not secret
///
/// The fingerprint is public: `nestwatch install` prints it on a console and a parent is
/// meant to read it aloud. Confidentiality is not the point. **Integrity** is — an
/// attacker who can rewrite the stored pin has defeated pinning completely, silently,
/// and permanently, because every later connection is then checked against their value.
///
/// `flutter_secure_storage` encrypts under a key held in the Android Keystore, with
/// AES-GCM as the storage cipher. AES-GCM is authenticated encryption, so tampering is
/// *detected* rather than merely inconvenienced, and that detection is the property
/// being bought here. Plain `SharedPreferences` offers neither on a rooted device.
///
/// Checked against flutter_secure_storage 11.0.0 rather than assumed: `AndroidOptions`
/// no longer accepts `encryptedSharedPreferences` at all — the Jetpack Security backend
/// it selected is deprecated and was removed in v11 — so the plain default is both
/// current and correct, and the widely-copied `AndroidOptions(encryptedSharedPreferences:
/// true)` incantation no longer compiles. `resetOnError` defaults to `true`, meaning
/// undecryptable data is cleared rather than thrown; that fails in the safe direction
/// here, because a lost pin forces re-pairing where a corrupt-but-enforced one would not.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'server_identity.dart';

class SecureServerIdentityStore implements ServerIdentityStore {
  /// Versioned so a future schema change cannot be misread as the current one.
  static const _key = 'nestwatch.server_identity.v1';

  final FlutterSecureStorage _storage;

  const SecureServerIdentityStore({
    this._storage = const FlutterSecureStorage(),
  });

  @override
  Future<ServerIdentity?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return ServerIdentity.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // Unreadable for any reason — corrupt, truncated, written by an older schema.
      // Drop it and re-pair rather than guessing: a half-understood pin is worse than no
      // pin, because it still gets enforced.
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(ServerIdentity identity) =>
      _storage.write(key: _key, value: jsonEncode(identity.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
