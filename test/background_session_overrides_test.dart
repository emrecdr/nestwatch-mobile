/// `openBackgroundSession` must pin a fresh isolate — and must not un-wire a live app.
///
/// The defect this file exists for: a notification action tapped while the app is running
/// is handled in the **UI** isolate, where `PairingController` holds the very
/// `PinnedHttpOverrides` instance `main` installed. Replacing the global there leaves
/// `trust()` and `distrust()` acting on an object nothing consults — so "Forget this PC"
/// would appear to work while the client kept the old pin.
///
/// Nothing in the app would report that. It is a reference going stale, not an error.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/background/background_session.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

class _Identities implements ServerIdentityStore {
  final ServerIdentity? stored;
  const _Identities(this.stored);
  @override
  Future<ServerIdentity?> load() async => stored;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Sessions implements SessionStore {
  final SessionCookie? stored;
  const _Sessions(this.stored);
  @override
  Future<SessionCookie?> load() async => stored;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final pin = Fingerprint.fromBytes(List<int>.filled(32, 3));
  final identity = ServerIdentity(
    host: '192.168.1.42',
    port: 8443,
    fingerprint: pin,
    provenance: PinProvenance.verifiedFromQrCode,
    pairedAt: DateTime(2026, 8, 31),
  );
  const cookie = SessionCookie('abc');

  tearDown(() => HttpOverrides.global = null);

  test('a fresh isolate gets pinned — nothing was installed before', () async {
    HttpOverrides.global = null;
    final session = await openBackgroundSession(
      identities: _Identities(identity),
      sessions: const _Sessions(cookie),
    );
    expect(session, isNotNull);
    expect(
      HttpOverrides.current,
      isA<PinnedHttpOverrides>(),
      reason: 'a background isolate starts unpinned; this is what fixes it',
    );
    expect((HttpOverrides.current! as PinnedHttpOverrides).pin, pin);
    session!.client.close();
  });

  test('a live app keeps the exact overrides object its controller holds', () async {
    // What main() does, and what PairingController is given a reference to.
    final appOverrides = PinnedHttpOverrides(pin: pin);
    HttpOverrides.global = appOverrides;

    final session = await openBackgroundSession(
      identities: _Identities(identity),
      sessions: const _Sessions(cookie),
    );
    expect(session, isNotNull);
    expect(
      identical(HttpOverrides.current, appOverrides),
      isTrue,
      reason:
          'replacing it would leave the controller holding an object nothing '
          'consults, so unpair() would not drop the pin from the live client',
    );
    session!.client.close();
  });

  test('and the controller can still change what is trusted afterwards', () async {
    // The consequence, stated as behaviour rather than as identity: distrust() on the
    // object the controller holds must still affect the installed override.
    final appOverrides = PinnedHttpOverrides(pin: pin);
    HttpOverrides.global = appOverrides;
    final session = await openBackgroundSession(
      identities: _Identities(identity),
      sessions: const _Sessions(cookie),
    );
    session!.client.close();

    appOverrides.distrust();
    expect(
      (HttpOverrides.current! as PinnedHttpOverrides).pin,
      isNull,
      reason: 'the parent pressed "Forget this PC"; the live client must forget it',
    );
  });

  test('unpaired stays null, and installs nothing', () async {
    HttpOverrides.global = null;
    final session = await openBackgroundSession(
      identities: const _Identities(null),
      sessions: const _Sessions(cookie),
    );
    expect(session, isNull);
    expect(HttpOverrides.current, isNull, reason: 'nothing to pin to');
  });
}
