/// The Keystore-backed [SignInNoticeStore].
///
/// Split from `sign_in_notice.dart` for the reason `secure_seen_requests.dart` gives at
/// length: `poll_logic.dart` imports the interface and must keep compiling under a plain
/// `dart run`, so the file holding it may not import `flutter_secure_storage`.
///
/// Stored rather than kept in memory because every poll is a fresh isolate — an in-memory
/// flag is `false` on arrival, every time, which is indistinguishable from "not yet told"
/// and would announce on every round.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sign_in_notice.dart';

/// Keystore-backed [SignInNoticeStore]. One key, present or absent.
class SecureSignInNotice implements SignInNoticeStore {
  static const _key = 'nestwatch.sign_in_notice.v1';

  final FlutterSecureStorage _storage;

  const SecureSignInNotice({this._storage = const FlutterSecureStorage()});

  /// Presence is the whole value; the string written is never read back. Storing a
  /// parsed `"true"`/`"false"` would add a case — a key holding something neither of
  /// those — for a flag that has no third state.
  @override
  Future<bool> announced() async => await _storage.read(key: _key) != null;

  @override
  Future<void> markAnnounced() => _storage.write(key: _key, value: '1');

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
