/// Which pairings this app will work with, and which it refuses before a screen renders.
///
/// ## The failure this closes
///
/// A dashboard link and an integration link are byte-identical in form —
/// `https://host:port/p/TOKEN#fp=…` — because the scope lives in that PC's `pairing.json`
/// and never in the URL. So the two QR codes look the same, and a parent hands over
/// whichever was on screen.
///
/// Handed the integration one, this app used to pair *successfully*. An integration
/// session may reach `POST /api/extra-time` and `GET /api/usage/today` and nothing else,
/// so **Today would have worked** while Requests, Screen and Codes each answered 403 — and
/// every 403 in this app was reported as "turn off your VPN". Live figures on one tab, a
/// network complaint on three, and no VPN anywhere in the story.
///
/// ## Absent and null are different answers
///
/// Every case below builds its session from a **raw payload**, because the distinction
/// that matters is between a key that is missing and a key whose value is null. nestwatch
/// makes that answerable deliberately: absent means "this build has no scopes" and needs no
/// action; present-and-null means "your session predates them" and needs re-pairing.
///
/// The first version of this file could not tell them apart. It passed `scope: null` for
/// both and leaned on `ContractCheck` to guess which, and the mutation audit caught it —
/// widening the version exemption survived, because no test here distinguished a PC that
/// is merely *newer* from one that is *behind*. Reading the key's presence is exact where
/// the version was a proxy.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/pairing/pairing_controller.dart';

/// A session exactly as `GET /session` put it on the wire.
///
/// `scope` is given as the raw JSON value, and omitted entirely when [withScopeKey] is
/// false — which is the only way to model a pre-0.6.0 answer honestly.
SessionInfo _session({
  bool authenticated = true,
  String version = '0.6.0',
  Object? scope,
  bool withScopeKey = true,
}) => SessionInfo.fromJson({
  'authenticated': authenticated,
  'version': version,
  if (withScopeKey) 'scope': scope,
});

void main() {
  group('the parent pairing is the one that works', () {
    test('a dashboard scope is accepted', () {
      expect(
        scopeRefusal(session: _session(scope: const {'kind': 'dashboard'})),
        isNull,
      );
    });

    test('an integration scope is refused, and named as such', () {
      final refusal = scopeRefusal(
        session: _session(
          scope: const {'kind': 'integration', 'source': 'studygo'},
        ),
      );
      expect(refusal, isNotNull);
      expect(refusal, contains('nestwatch pair'));
      expect(
        refusal,
        contains('integration'),
        reason: 'a parent has to know which of the two codes they scanned',
      );
      // The remedy is to re-pair, not to touch the network. Saying anything about Wi-Fi
      // here is the defect this exists to remove.
      expect(refusal!.toLowerCase(), isNot(contains('vpn')));
      expect(refusal.toLowerCase(), isNot(contains('wi-fi')));
    });

    test('a kind this build has never heard of is refused too', () {
      // Fails closed. A future nestwatch inventing a third kind must not have it read as
      // permission by an app that predates it -- and folding an unknown into the narrower
      // known kind would be this app inventing a bound the server never stated.
      expect(
        scopeRefusal(session: _session(scope: const {'kind': 'kiosk'})),
        isNotNull,
      );
    });
  });

  group('absent and null are different answers', () {
    test('no scope key at all is a pre-0.6.0 PC, and is left alone', () {
      // The load-bearing exemption. Refusing here would lock this app out of every PC that
      // has not upgraded, over a field those builds never claimed to send -- and such a
      // build has no integration pairings to be handed, because the feature did not exist.
      expect(
        scopeRefusal(session: _session(version: '0.5.0', withScopeKey: false)),
        isNull,
      );
    });

    test('an explicit null scope is a lapsed session, and is refused', () {
      // Same *value* as the case above and the opposite answer. On a server that reports
      // scopes this means a session minted before they existed, which `require_auth`
      // refuses outright -- so reading it as permission here would have this app believe
      // something that PC does not.
      final refusal = scopeRefusal(session: _session(scope: null));
      expect(refusal, isNotNull);
      expect(refusal, contains('Pair again'));
    });

    test('and the version is not consulted for either', () {
      // What the surviving mutation was about. The exemption used to key on
      // `ContractCheck.serverOlder`, so a *newer* PC sending no usable scope took a
      // different path from an agreed one -- a distinction no test made, which is why
      // widening it survived. Presence is now the whole rule, and these four say so: the
      // version moves across the entire range and changes nothing.
      for (final version in ['0.4.0', '0.6.0', '9.9.9', 'not-a-version']) {
        expect(
          scopeRefusal(session: _session(version: version, scope: null)),
          isNotNull,
          reason:
              'present-and-null is refused whatever the version says ($version)',
        );
        expect(
          scopeRefusal(
            session: _session(version: version, withScopeKey: false),
          ),
          isNull,
          reason: 'absent is exempt whatever the version says ($version)',
        );
      }
    });
  });

  group('nothing is refused before there is a session to refuse', () {
    test('an unauthenticated probe passes through', () {
      // `_probe` runs before redemption and before the password, and answers
      // `authenticated: false` with a null scope every time. Refusing that would break
      // pairing at the first step, on every server.
      expect(
        scopeRefusal(session: _session(authenticated: false, scope: null)),
        isNull,
      );
      expect(
        scopeRefusal(
          session: _session(authenticated: false, withScopeKey: false),
        ),
        isNull,
      );
    });
  });
}
