import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/session_cookie.dart';
import 'package:nestwatch_mobile/src/pairing/session_store.dart';

void main() {
  group('SessionCookie', () {
    test('carries the name nestwatch sets', () {
      // with_name("hh_session") in nestwatch src/server.rs.
      expect(SessionCookie.name, 'hh_session');
      expect(const SessionCookie('abc').toCookie().name, 'hh_session');
    });

    test('only the value is kept, because only the value travels', () {
      // Secure / HttpOnly / SameSite / Max-Age are instructions from server to browser.
      // A `Cookie:` request header carries name and value and nothing else, so storing
      // the rest would be keeping a copy of the server's own policy.
      const cookie = SessionCookie('opaque-value');
      expect(cookie.toCookie().value, 'opaque-value');
      expect(cookie.value, 'opaque-value');
    });

    test(
      'never renders the value — it is a bearer token for the dashboard',
      () {
        const secret = 'a-session-that-controls-a-childs-pc';
        const cookie = SessionCookie(secret);
        expect(cookie.toString(), isNot(contains(secret)));
        expect(cookie.toString(), contains('redacted'));
        // Interpolation is the accident this guards against.
        expect('$cookie', isNot(contains(secret)));
      },
    );

    test('equality is by value, so re-issue is detectable', () {
      expect(const SessionCookie('a'), const SessionCookie('a'));
      expect(const SessionCookie('a'), isNot(const SessionCookie('b')));
    });
  });

  group('InMemorySessionStore', () {
    test('round-trips and clears', () async {
      final store = InMemorySessionStore();
      expect(await store.load(), isNull);
      await store.save(const SessionCookie('v1'));
      expect(await store.load(), const SessionCookie('v1'));
      // Re-issue on sliding-expiry refresh must overwrite, not accumulate.
      await store.save(const SessionCookie('v2'));
      expect(await store.load(), const SessionCookie('v2'));
      await store.clear();
      expect(await store.load(), isNull);
    });
  });
}
