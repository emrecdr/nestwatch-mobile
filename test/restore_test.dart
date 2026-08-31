/// What has to be true before the first frame, and what must not block it.
///
/// `main()` awaits [PairingController.restorePin] and then calls `runApp`. The ordering
/// carries a security property — the process is never briefly unpinned while a
/// previously-paired PC is reachable — and it used to carry a network round trip with it,
/// because both halves were one method.
///
/// That cost a blank screen for a TLS handshake and a GET on every launch. On the home
/// LAN, tens of milliseconds. Off it — a parent checking from work — the probe runs to
/// the 10-second timeout, applied to opening the request and again to closing it.
///
/// Splitting them is what makes this file possible: [restorePin] touches no network, so
/// a plain test can hold it to both halves of the claim. Before the split the only thing
/// that could was `tool/prove_login.dart`, which needs a live PC and the control
/// password.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

void main() {
  final pin = Fingerprint.parse(
    'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:'
    'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
  );

  final paired = ServerIdentity(
    host: '10.0.0.5',
    port: 8443,
    fingerprint: pin,
    provenance: PinProvenance.verifiedFromQrCode,
    pairedAt: DateTime.utc(2026, 8, 26),
  );

  Future<PairingController> controllerWith({
    ServerIdentity? identity,
    SessionCookie? cookie,
    required PinnedHttpOverrides overrides,
  }) async {
    final identities = InMemoryServerIdentityStore();
    final sessions = InMemorySessionStore();
    if (identity != null) await identities.save(identity);
    if (cookie != null) await sessions.save(cookie);
    return PairingController(
      overrides: overrides,
      identities: identities,
      sessions: sessions,
      seen: InMemorySeenRequestStore(),
    );
  }

  group('restorePin — awaited before the first frame', () {
    test('re-applies the stored pin', () async {
      final overrides = PinnedHttpOverrides();
      expect(overrides.pin, isNull, reason: 'a fresh process starts unpinned');

      final c = await controllerWith(
        identity: paired,
        cookie: const SessionCookie('a-session'),
        overrides: overrides,
      );
      await c.restorePin();

      expect(
        overrides.pin,
        pin,
        reason:
            'the process must never be briefly unpinned while that PC is reachable',
      );
    });

    test(
      'with a session to check, it says so rather than showing nothing',
      () async {
        final c = await controllerWith(
          identity: paired,
          cookie: const SessionCookie('a-session'),
          overrides: PinnedHttpOverrides(),
        );
        await c.restorePin();
        expect(c.state, isA<PairingBusy>());
      },
    );

    test(
      'with no stored session it goes straight to the password prompt',
      () async {
        final c = await controllerWith(
          identity: paired,
          overrides: PinnedHttpOverrides(),
        );
        await c.restorePin();
        expect(c.state, isA<PairingNeedsPassword>());
        expect(
          (c.state as PairingNeedsPassword).reason,
          PasswordPrompt.sessionLapsed,
        );
      },
    );

    test('an unpaired device pins nothing and asks for nothing', () async {
      final overrides = PinnedHttpOverrides();
      final c = await controllerWith(overrides: overrides);
      await c.restorePin();
      expect(overrides.pin, isNull);
      expect(c.state, isA<PairingIdle>());
    });
  });

  group('restoreSession — started behind the first frame', () {
    test('does nothing when restorePin left nothing to verify', () async {
      // No stored identity, so no client and no question to ask. It must return rather
      // than reach for a null client.
      final c = await controllerWith(overrides: PinnedHttpOverrides());
      await c.restorePin();
      await c.restoreSession();
      expect(c.state, isA<PairingIdle>());
    });

    test('does not overwrite a state the parent is already looking at', () async {
      // No cookie, so restorePin puts up the password prompt. restoreSession runs after
      // runApp and could land on a parent mid-typing; it must leave them alone.
      final c = await controllerWith(
        identity: paired,
        overrides: PinnedHttpOverrides(),
      );
      await c.restorePin();
      expect(c.state, isA<PairingNeedsPassword>());

      await c.restoreSession();
      expect(
        c.state,
        isA<PairingNeedsPassword>(),
        reason: 'only a PairingBusy left by restorePin is its to resolve',
      );
    });
  });

  group('unpair deletes what the privacy screen says it deletes', () {
    // PrivacyScreen lists three stored items and says "Forget this PC" deletes all of
    // them. It cleared two. An inaccuracy anywhere else is a bug; in a privacy policy it
    // is a false statement about data handling, in the document Play requires to be true.
    //
    // It left a real trace too: those identifiers are what suppress a second
    // notification, so a re-paired phone would stay quiet about requests it had
    // "already announced" to a pairing that no longer exists.
    test('the pin, the cookie, and the announced-request identifiers', () async {
      final identities = InMemoryServerIdentityStore();
      final sessions = InMemorySessionStore();
      final seen = InMemorySeenRequestStore();
      await identities.save(
        ServerIdentity(
          host: '192.168.1.42',
          port: 8443,
          fingerprint: Fingerprint.fromBytes(List<int>.filled(32, 9)),
          provenance: PinProvenance.verifiedFromQrCode,
          pairedAt: DateTime(2026, 8, 31),
        ),
      );
      await sessions.save(const SessionCookie('cookie'));
      await seen.save({'r1', 'r2'});

      final controller = PairingController(
        overrides: PinnedHttpOverrides(),
        identities: identities,
        sessions: sessions,
        seen: seen,
      );
      await controller.unpair();

      expect(await identities.load(), isNull, reason: 'the pin');
      expect(await sessions.load(), isNull, reason: 'the cookie');
      expect(await seen.load(), isEmpty, reason: 'the announced-request identifiers');
    });
  });
}
