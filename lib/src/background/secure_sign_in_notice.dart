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

/// Keystore-backed [SignInNoticeStore]. One key, holding when the parent was told.
class SecureSignInNotice implements SignInNoticeStore {
  static const _key = 'nestwatch.sign_in_notice.v1';

  final FlutterSecureStorage _storage;

  const SecureSignInNotice({this._storage = const FlutterSecureStorage()});

  /// An unreadable value reads as **never told**, and the key is left alone.
  ///
  /// It has two causes and they want the same answer. One is an install upgrading across
  /// the change that put a time here: this key used to hold `'1'`, because presence was
  /// once the whole value. The other is any future corruption. Both resolve on the next
  /// round — a notice is given, a parseable time is written over the top — where reading
  /// a bad value as "already told" would strand the phone in the silence this whole
  /// mechanism exists to prevent. One extra notification is the right price, and it is
  /// paid once.
  ///
  /// The key is not renamed for the format change, deliberately: a `v2` would leave `v1`
  /// behind in the Keystore, and every stored item is one the privacy screen has to be
  /// able to account for. See `store_requirements_test.dart`.
  @override
  Future<DateTime?> announcedAt() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  /// ISO-8601, in UTC. A local-time string would be re-read after a timezone change as a
  /// different instant than the one written, which is the one input the elapsed-time rule
  /// in [SignInNotice] has.
  @override
  Future<void> markAnnounced(DateTime at) =>
      _storage.write(key: _key, value: at.toUtc().toIso8601String());

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
