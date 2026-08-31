/// Which of the two things went wrong: this phone, or that PC.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/reachability.dart';

void main() {
  Whereabouts at(String server, List<String> local) =>
      whereAmI(serverHost: server, localAddresses: local);

  group('the three answers', () {
    test('no usable address is offline, and blames nothing', () {
      expect(at('192.168.1.42', const []), Whereabouts.offline);
      final said = explainUnreachable(Whereabouts.offline, '192.168.1.42:8443');
      expect(said, contains('Nothing is wrong with that PC'));
    });

    test('same /24 stops blaming the network and starts believing the PC', () {
      expect(at('192.168.1.42', ['192.168.1.105']), Whereabouts.looksLikeHome);
      expect(
        explainUnreachable(Whereabouts.looksLikeHome, '192.168.1.42:8443'),
        contains('switched off'),
      );
    });

    test(
      'a different range reads as elsewhere, and says why that is expected',
      () {
        expect(at('192.168.1.42', ['10.55.0.9']), Whereabouts.looksElsewhere);
        final said = explainUnreachable(
          Whereabouts.looksElsewhere,
          '192.168.1.42:8443',
        );
        expect(said, contains('home Wi-Fi'));
        expect(
          said,
          contains('never goes through the internet'),
          reason:
              'the limitation is the design, so say so rather than apologise',
        );
      },
    );
  });

  group('addresses that say nothing', () {
    test('loopback alone is not a network', () {
      expect(at('192.168.1.42', ['127.0.0.1']), Whereabouts.offline);
    });

    test('a link-local address means DHCP never answered', () {
      // 169.254.x.x is what a phone assigns itself when nothing replied. Treating it as
      // a real network would report "you are elsewhere" to somebody standing at home.
      expect(at('192.168.1.42', ['169.254.11.9']), Whereabouts.offline);
    });

    test('a real address alongside loopback still counts', () {
      expect(
        at('192.168.1.42', ['127.0.0.1', '192.168.1.7']),
        Whereabouts.looksLikeHome,
      );
    });
  });

  group('what cannot be computed is not guessed', () {
    test('a hostname is not an address', () {
      expect(at('nestwatch.local', ['192.168.1.7']), Whereabouts.cannotTell);
    });

    test('and it still says the useful half', () {
      expect(
        explainUnreachable(Whereabouts.cannotTell, 'nestwatch.local:8443'),
        contains('away from home'),
      );
    });

    for (final bad in ['', '1.2.3', '1.2.3.4.5', '999.1.1.1', 'a.b.c.d']) {
      test('"$bad" is not an address', () {
        expect(at(bad, ['192.168.1.7']), Whereabouts.cannotTell);
      });
    }
  });

  test('no sentence leaks an errno at a parent', () {
    // The whole point. Every branch is checked, so a fourth added later cannot slip out
    // holding the OS's words.
    for (final w in Whereabouts.values) {
      final said = explainUnreachable(w, '192.168.1.42:8443');
      expect(said, isNot(contains('errno')));
      expect(said, isNot(contains('No route')));
      expect(said, contains('192.168.1.42:8443'));
    }
  });
}
