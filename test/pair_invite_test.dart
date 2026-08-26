import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/pairing/pair_invite.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';

void main() {
  const fp =
      'FC:55:3F:C4:95:90:0A:F2:FB:01:6D:A9:80:F8:38:D4:'
      '03:EE:AF:DB:25:12:C4:50:7F:58:AC:9F:C9:B1:D4:7E';
  const base = 'https://192.168.0.78:8443/p/EG629F4DQDDHS44V';

  group('the QR nestwatch prints today', () {
    test('parses, and reports that it cannot be verified', () {
      final invite = PairInvite.parse(base);
      expect(invite.host, '192.168.0.78');
      expect(invite.port, 8443);
      expect(invite.token, 'EG629F4DQDDHS44V');
      expect(invite.fingerprint, isNull);
      expect(invite.isVerifiable, isFalse);
    });

    test('surrounding whitespace from a scan is tolerated', () {
      expect(PairInvite.parse('  $base \n').token, 'EG629F4DQDDHS44V');
    });
  });

  group('the QR Phase 1 will print', () {
    test('carries the fingerprint, and it is verifiable', () {
      final invite = PairInvite.parse('$base#fp=$fp');
      expect(invite.fingerprint, Fingerprint.parse(fp));
      expect(invite.isVerifiable, isTrue);
      // The fragment must not leak into anything sent to the server.
      expect(invite.redeemUrl.toString(), base);
    });

    test('an unknown extra fragment key does not break it', () {
      // Forward compatibility: a later server adding a second key must not make the
      // whole QR unreadable to this build.
      final invite = PairInvite.parse('$base#v=2&fp=$fp&note=hello');
      expect(invite.fingerprint, Fingerprint.parse(fp));
    });

    test('a percent-encoded fingerprint still parses', () {
      final encoded = Uri.encodeComponent(fp);
      expect(
        PairInvite.parse('$base#fp=$encoded').fingerprint,
        Fingerprint.parse(fp),
      );
    });

    test('a DAMAGED fingerprint is an error, not a quiet fall back to TOFU', () {
      // This is the security-relevant one. Treating an unreadable `fp` as "no
      // fingerprint" would silently turn verified first use into trust-on-first-use —
      // a downgrade caused by a bad scan, reported as nothing at all.
      expect(
        () => PairInvite.parse('$base#fp=NOTAFINGERPRINT'),
        throwsA(isA<PairInviteFormatException>()),
      );
      expect(
        () => PairInvite.parse('$base#fp=${fp.substring(0, 40)}'),
        throwsA(isA<PairInviteFormatException>()),
      );
    });
  });

  group('payloads that are not nestwatch pairing codes', () {
    test('http is refused — a pin cannot protect cleartext', () {
      expect(
        () => PairInvite.parse('http://192.168.0.78:8443/p/ABC'),
        throwsA(isA<PairInviteFormatException>()),
      );
    });

    test('some other https link is refused', () {
      for (final url in [
        'https://example.com',
        'https://example.com/login',
        'https://192.168.0.78:8443/p/A/B',
        'https://192.168.0.78:8443/pair/ABC',
      ]) {
        expect(
          () => PairInvite.parse(url),
          throwsA(isA<PairInviteFormatException>()),
          reason: url,
        );
      }
    });

    test('plain text and empties are refused', () {
      for (final junk in ['', '   ', 'hello world', 'WIFI:S:home;T:WPA;']) {
        expect(
          () => PairInvite.parse(junk),
          throwsA(isA<PairInviteFormatException>()),
          reason: '"$junk"',
        );
      }
    });
  });

  group('the port', () {
    test('an explicit port is kept', () {
      expect(PairInvite.parse('https://h:9000/p/ABC').port, 9000);
    });

    test("a missing port becomes nestwatch's 8443, not https's 443", () {
      // Uri.parse supplies the scheme default (443) for a portless https URL. Accepting
      // that would connect to the wrong port and surface as "server unreachable".
      expect(Uri.parse('https://h/p/ABC').port, 443, reason: 'Dart behaviour');
      expect(PairInvite.parse('https://h/p/ABC').port, nestwatchDefaultPort);
      expect(nestwatchDefaultPort, 8443);
    });
  });

  group('token normalisation mirrors the server', () {
    // nestwatch `redeem` calls `token::normalize` before comparing: uppercase, keep
    // only ASCII alphanumerics. Matching that here means the app judges a token by the
    // same rule the server will.
    test('lowercase and separators are canonicalised', () {
      expect(
        PairInvite.parse('https://h:1/p/eg629f4dqddhs44v').token,
        'EG629F4DQDDHS44V',
      );
      expect(normalizeToken('abcd-1234'), 'ABCD1234');
      expect(normalizeToken('ABCD 1234'), 'ABCD1234');
      expect(normalizeToken(''), '');
    });

    test('a path segment with no alphanumerics at all is refused', () {
      expect(
        () => PairInvite.parse('https://h:1/p/---'),
        throwsA(isA<PairInviteFormatException>()),
      );
    });
  });

  group('a typed address', () {
    test('has no token, which is the same place a spent token leaves us', () {
      final manual = PairInvite.manual(host: '10.0.0.5', port: 8443);
      expect(manual.token, isNull);
      expect(manual.redeemUrl, isNull);
      expect(manual.isVerifiable, isFalse);
      expect(manual.sessionUrl.toString(), 'https://10.0.0.5:8443/session');
    });
  });
}
