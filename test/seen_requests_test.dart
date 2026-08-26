import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';

void main() {
  group('diffPending', () {
    test('everything is new the first time', () {
      final d = diffPending(['a', 'b'], {});
      expect(d.fresh, {'a', 'b'});
      expect(d.next, {'a', 'b'});
    });

    test('nothing is new the second time', () {
      // The property that stops a 15-minute poll re-announcing the same request four
      // times an hour, which is what teaches a parent to swipe it away unread.
      final d = diffPending(['a', 'b'], {'a', 'b'});
      expect(d.fresh, isEmpty);
      expect(d.next, {'a', 'b'});
    });

    test('only the genuinely new one is fresh', () {
      final d = diffPending(['a', 'b', 'c'], {'a', 'b'});
      expect(d.fresh, {'c'});
      expect(d.next, {'a', 'b', 'c'});
    });

    test('resolved ids are pruned, not accumulated', () {
      // `next` is what is pending, not the union. An id kept after its request was
      // resolved is dead weight at best; if the server could ever reuse one it would be
      // silently suppressed.
      final d = diffPending(['c'], {'a', 'b', 'c'});
      expect(d.next, {'c'});
      expect(d.fresh, isEmpty);
    });

    test('an emptied queue empties the set', () {
      final d = diffPending([], {'a', 'b'});
      expect(d.next, isEmpty);
      // The caller withdraws notifications for seen - next, which is everything here.
      expect({'a', 'b'}.difference(d.next), {'a', 'b'});
    });

    test('a request that reappears after being pruned is announced again', () {
      // Correct: the set means "pending requests already announced", not "every id ever
      // seen". Something back in the queue is something to mention.
      final gone = diffPending([], {'a'});
      final back = diffPending(['a'], gone.next);
      expect(back.fresh, {'a'});
    });
  });

  group('InMemorySeenRequestStore', () {
    test('round-trips', () async {
      final store = InMemorySeenRequestStore();
      expect(await store.load(), isEmpty);
      await store.save({'x', 'y'});
      expect(await store.load(), {'x', 'y'});
      await store.save({'y'});
      expect(await store.load(), {'y'});
    });
  });
}
