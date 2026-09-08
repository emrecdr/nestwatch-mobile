/// A PC that changed address, and the question the app already knew the answer to.
///
/// `ServerIdentity` stores `host` and `port` and nothing ever revisits them, so a DHCP
/// lease change leaves the app pinned to a certificate it can no longer find. The pin
/// itself is fine — `docs/PLAN.md` §5 is right that hostname verification is gone — but
/// the *addressing* half is untouched, and the recovery a parent is offered is "Type the
/// address instead", which carries no fingerprint.
///
/// That landed in the trust-on-first-use branch: drop the pin, observe the certificate,
/// and ask a human to compare 64 hex characters against a Windows console. For a
/// certificate already on file. `M22` calls conflating that with a genuinely new
/// certificate "how a parent gets trained to click through fingerprint comparisons" — the
/// habit `PLAN.md` §5 quotes nestwatch on depending on them not having.
///
/// ## Why this file drives a real handshake
///
/// The decision is made from a certificate observed on the wire. A test that handed the
/// controller a `Fingerprint` object would be asserting that two values this test invented
/// compare equal, which is `M26`'s shape: the input derives from the thing under test, so
/// it cannot see it change. The certificate here is served by a real TLS server and read
/// back out of a refused handshake, exactly as it is in the app.
///
/// Every test carries the control that the rig can produce the other answer, because the
/// interesting assertions are all *negative* — nobody was asked, nothing was relabelled —
/// and a rig that reached nothing at all would pass every one of them.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/background/sign_in_notice.dart';
import 'package:nestwatch_mobile/src/pairing/pair_invite.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';
import 'package:nestwatch_mobile/src/pairing/server_identity.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'package:nestwatch_mobile/src/ui/pairing_screen.dart';

import 'support/certs.dart';
import 'support/tls_server.dart';

void main() {
  late TestTlsServer server;
  late InMemoryServerIdentityStore identities;
  late InMemorySessionStore sessions;

  /// A signed-in answer from a PC new enough to carry a scope this app can use.
  const signedIn =
      '{"authenticated":true,"version":"0.7.0","scope":{"kind":"dashboard"}}';

  /// The day the pairing was originally made — which a re-address must not overwrite.
  final pairedOn = DateTime.utc(2026, 7, 1);

  setUp(() async {
    server = await TestTlsServer.start(body: signedIn);
    identities = InMemoryServerIdentityStore();
    sessions = InMemorySessionStore();
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close();
  });

  /// Where the app thinks that PC is: the right certificate, the wrong port.
  ///
  /// A port rather than a host because loopback is the only address a test server has.
  /// The controller compares `authority`, so a stale port exercises the same path a stale
  /// IP address would, and `restorePin` makes no network calls — nothing has to be
  /// listening on it.
  Future<void> storeIdentity({
    required Fingerprint fingerprint,
    PinProvenance provenance = PinProvenance.verifiedFromQrCode,
  }) => identities.save(
    ServerIdentity(
      host: '127.0.0.1',
      port: server.port + 1,
      fingerprint: fingerprint,
      provenance: provenance,
      pairedAt: pairedOn,
    ),
  );

  /// A controller that has already restored whatever was stored, as a launch would.
  Future<PairingController> launched() async {
    final overrides = PinnedHttpOverrides();
    // `HttpClient()` consults `HttpOverrides.current`; the controller's own reference is
    // only used for trust/distrust.
    HttpOverrides.global = overrides;
    final controller = PairingController(
      overrides: overrides,
      identities: identities,
      sessions: sessions,
      forgetAnnounced: InMemorySeenRequestStore().clear,
      withdrawSignInNotice: SignInNotice.recording().lower,
    );
    await controller.restorePin();
    return controller;
  }

  /// The parent typing the address it moved to.
  PairInvite theNewAddress() =>
      PairInvite.manual(host: '127.0.0.1', port: server.port);

  group('the certificate at the new address is the one already pinned', () {
    test('so nobody is asked to compare anything', () async {
      await storeIdentity(fingerprint: server.pin);
      final c = await launched();

      await c.begin(theNewAddress());

      expect(
        c.state,
        isNot(isA<PairingNeedsFingerprintCheck>()),
        reason:
            'the app is holding this exact fingerprint; asking a human to read it off '
            'a console is asking a question it can answer itself',
      );
      expect(
        c.state,
        isA<PairingConnected>(),
        reason:
            'and the control: it has to actually get there, or every negative '
            'assertion in this file passes by reaching nothing',
      );
    });

    test('the address it moved to is what gets remembered', () async {
      await storeIdentity(fingerprint: server.pin);
      final c = await launched();

      await c.begin(theNewAddress());

      expect(c.current?.port, server.port);
      expect(
        (await identities.load())?.port,
        server.port,
        reason: 'and it survives the app being closed, which is the point',
      );
    });

    test(
      'it keeps the trust it already had rather than being relabelled',
      () async {
        await storeIdentity(fingerprint: server.pin);
        final c = await launched();

        await c.begin(theNewAddress());

        expect(
          (await identities.load())?.provenance,
          PinProvenance.verifiedFromQrCode,
          reason:
              'a PC verified from a QR code was permanently downgraded to '
              'trust-on-first-use by the act of moving house',
        );
      },
    );

    test('trust is carried over, never raised', () async {
      await storeIdentity(
        fingerprint: server.pin,
        provenance: PinProvenance.trustedOnFirstUse,
      );
      final c = await launched();

      await c.begin(theNewAddress());

      expect(
        (await identities.load())?.provenance,
        PinProvenance.trustedOnFirstUse,
        reason:
            'seeing the same certificate again is not new evidence about how well the '
            'parent compared it the first time',
      );
    });

    test(
      'and the day it was paired, because that did not happen again',
      () async {
        await storeIdentity(fingerprint: server.pin);
        final c = await launched();

        await c.begin(theNewAddress());

        expect((await identities.load())?.pairedAt, pairedOn);
      },
    );

    test('the session comes with it, so a lease change costs no password', () async {
      await storeIdentity(fingerprint: server.pin);
      await sessions.save(const SessionCookie('a-session'));
      final c = await launched();

      await c.begin(theNewAddress());

      expect(
        c.state,
        isA<PairingConnected>(),
        reason:
            'not PairingNeedsPassword — the same server, so the same session',
      );
      expect(
        server.cookiesSeen,
        // Spelled out rather than built from `SessionCookie.name`, which is a value in
        // the code under test. The name is nestwatch's — `with_name("hh_session")` in
        // its `src/server.rs` — so a test deriving it here could not notice this app
        // renaming it. `api_wire_test.dart` hard-codes it for the same reason.
        ['hh_session=a-session'],
        reason:
            'the wire, because a server answering signed-in either way cannot tell '
            'you whether the cookie was actually sent. Exactly one entry: the '
            'observation handshake is refused, so it reaches nothing.',
      );
    });
  });

  group('when the reconnect itself fails', () {
    test('the pin it already had is not thrown away', () async {
      // A server that answers, so the handshake and therefore the recognition both
      // succeed, and then fails the request. `restorePin` runs once per launch, so a pin
      // dropped here stays dropped until the app is restarted — over a network blip, for
      // a certificate nothing has cast any doubt on.
      await server.close();
      server = await TestTlsServer.start(status: 500);
      await storeIdentity(fingerprint: server.pin);
      final c = await launched();
      final overrides = HttpOverrides.current! as PinnedHttpOverrides;

      await c.begin(theNewAddress());

      expect(
        c.state,
        isA<PairingFailed>(),
        reason: 'the control: the reconnect has to have actually failed',
      );
      expect(overrides.pin, server.pin);
    });
  });

  group('and when it is not that certificate, the human is still asked', () {
    test('a different certificate at that address stops and asks', () async {
      await storeIdentity(
        fingerprint: fingerprintOf('$fixtureDir/impostor.cert.pem'),
      );
      final c = await launched();

      await c.begin(theNewAddress());

      expect(
        c.state,
        isA<PairingNeedsFingerprintCheck>(),
        reason:
            'the app cannot tell a rotated certificate from a different PC entirely, '
            'and only the parent can',
      );
      expect(
        server.cookiesSeen,
        isEmpty,
        reason: 'and nothing reached it while the question was open',
      );
    });

    test('with nothing stored, the first pairing is unchanged', () async {
      final c = await launched();

      await c.begin(theNewAddress());

      expect(c.state, isA<PairingNeedsFingerprintCheck>());
      expect(
        (c.state as PairingNeedsFingerprintCheck).replacing,
        isNull,
        reason: 'nothing to replace, so nothing to warn about',
      );
    });

    test('and the screen is told what saying yes would end', () async {
      await storeIdentity(
        fingerprint: fingerprintOf('$fixtureDir/impostor.cert.pem'),
      );
      final c = await launched();

      await c.begin(theNewAddress());

      expect(
        (c.state as PairingNeedsFingerprintCheck).replacing?.port,
        server.port + 1,
        reason:
            'everyone who reaches this screen holding a pairing is now here for one '
            'reason — the certificate is not the one on file — and agreeing ends the '
            'pairing they have',
      );
    });

    test(
      'a stored fingerprint is not enough on its own — it has to match',
      () async {
        // The control for the control. If `storeIdentity` were quietly failing, the two
        // tests above would pass for the wrong reason.
        await storeIdentity(fingerprint: server.pin);
        final c = await launched();
        expect(c.current?.fingerprint, server.pin);
      },
    );
  });

  /// The words themselves, held directly.
  ///
  /// `replacementWarning` and `trustButtonLabel` are top level and pure so this does not
  /// need a widget, a TLS server and a controller in order to assert a paragraph — the
  /// same reason `bedtimeConfirmation` was extracted, which also got a branch covered
  /// that a widget test could not reach.
  group('the words on that screen', () {
    final replaced = ServerIdentity(
      host: '10.0.0.5',
      port: 8443,
      fingerprint: Fingerprint.parse(
        'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:'
        'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
      ),
      provenance: PinProvenance.verifiedFromQrCode,
      pairedAt: DateTime.utc(2026, 7, 1),
    );

    test('say nothing at all when there is nothing to replace', () {
      expect(replacementWarning(null, '10.0.0.9:8443'), isNull);
      expect(trustButtonLabel(null), contains('trust this PC'));
    });

    test('name both PCs, so it is clear which is which', () {
      final said = replacementWarning(replaced, '10.0.0.9:8443')!;
      expect(said, contains('10.0.0.5:8443'));
      expect(said, contains('10.0.0.9:8443'));
    });

    test('offer the innocent explanations and the other one', () {
      final said = replacementWarning(replaced, '10.0.0.9:8443')!;
      expect(said, contains('a different PC'));
      expect(said, contains('new certificate'));
      expect(
        said,
        contains('anything on the network can answer for an address'),
        reason:
            'two ordinary explanations with no third would read as reassurance, and '
            'this screen exists because only the parent can tell the three apart',
      );
    });

    test('state the consequence, which the screen never used to', () {
      expect(
        replacementWarning(replaced, '10.0.0.9:8443'),
        contains('would have to be paired again'),
        reason:
            '`_persistIdentity` overwrites — agreeing ends the pairing this app has, '
            'and that is not a thing to find out afterwards',
      );
    });

    test('and the button says what it will do', () {
      expect(trustButtonLabel(replaced), contains('replace'));
    });
  });
}
