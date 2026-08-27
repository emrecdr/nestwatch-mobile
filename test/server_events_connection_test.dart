/// The reconnecting half: what happens when a stream ends, and what must not.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/api/server_events.dart';

void main() {
  test('subjects arrive expanded, so `all` is never a word to interpret', () {
    final seen = <String>[];
    final events = ServerEvents(
      open: () => Stream.fromIterable(['requests', 'all', 'weather']),
      onChanged: seen.add,
    );
    events.start();
    // The stream is synchronous-ish; drain a microtask turn.
    return Future<void>.delayed(Duration.zero, () {
      expect(seen, containsAll(<String>['requests', 'usage']));
      expect(seen, isNot(contains('all')));
      expect(seen, isNot(contains('weather')));
      events.stop();
    });
  });

  test('a dropped stream is retried, with the delay doubling', () {
    fakeAsync((async) {
      var opens = 0;
      final events = ServerEvents(
        open: () {
          opens++;
          return Stream<String>.error(const SocketFailure());
        },
        onChanged: (_) {},
      );
      events.start();
      async.flushMicrotasks();
      expect(opens, 1, reason: 'the first attempt is immediate');

      async.elapse(const Duration(seconds: 1));
      expect(opens, 2);

      async.elapse(const Duration(seconds: 2));
      expect(opens, 3);

      async.elapse(const Duration(seconds: 4));
      expect(opens, 4);

      // ...and it stops growing rather than drifting into hours.
      async.elapse(const Duration(minutes: 5));
      final afterFiveMinutes = opens;
      async.elapse(const Duration(seconds: 30));
      expect(opens, afterFiveMinutes + 1, reason: 'capped at 30s');

      events.stop();
    });
  });

  test('an event resets the backoff, but merely connecting does not', () {
    fakeAsync((async) {
      var opens = 0;
      final events = ServerEvents(
        open: () {
          opens++;
          // Connects cleanly, delivers nothing, ends. A server doing this would turn a
          // connect-resets-backoff policy into a busy loop that calls itself healthy.
          return const Stream<String>.empty();
        },
        onChanged: (_) {},
      );
      events.start();
      async.flushMicrotasks();
      expect(opens, 1);

      async.elapse(const Duration(seconds: 1));
      expect(opens, 2);
      async.elapse(const Duration(seconds: 1));
      expect(opens, 2, reason: 'the wait grew, so one second is no longer enough');
      async.elapse(const Duration(seconds: 1));
      expect(opens, 3);

      events.stop();
    });
  });

  test('isReceiving is false until something actually arrives', () {
    fakeAsync((async) {
      final controller = StreamController<String>();
      final events = ServerEvents(
        open: () => controller.stream,
        onChanged: (_) {},
      );
      events.start();
      async.flushMicrotasks();
      expect(events.isReceiving, isFalse, reason: 'connected is not receiving');

      controller.add('usage');
      async.flushMicrotasks();
      expect(events.isReceiving, isTrue);

      controller.close();
      async.flushMicrotasks();
      expect(events.isReceiving, isFalse, reason: 'a closed stream delivers nothing');
      events.stop();
    });
  });

  test('a lapsed session is handed up, not retried', () {
    fakeAsync((async) {
      var opens = 0;
      Object? fatal;
      final events = ServerEvents(
        open: () {
          opens++;
          return Stream<String>.error(
            const NestwatchException(
              NestwatchFailure.sessionExpired,
              'That sign-in expired.',
            ),
          );
        },
        onChanged: (_) {},
        onFatal: (e) => fatal = e,
      );
      events.start();
      async.flushMicrotasks();
      expect(opens, 1);
      expect(fatal, isA<NestwatchException>());

      // Reconnecting cannot fix a 401, and hammering a PC that is answering correctly
      // is the worst possible response to it.
      async.elapse(const Duration(minutes: 10));
      expect(opens, 1);
    });
  });

  test('stop() ends it, and a pending retry does not resurrect it', () {
    fakeAsync((async) {
      var opens = 0;
      final events = ServerEvents(
        open: () {
          opens++;
          return Stream<String>.error(const SocketFailure());
        },
        onChanged: (_) {},
      );
      events.start();
      async.flushMicrotasks();
      expect(opens, 1);
      events.stop();
      async.elapse(const Duration(minutes: 10));
      expect(opens, 1);
    });
  });
}

/// Any non-fatal transport error. The class does not inspect it beyond the one case it
/// must treat differently, so a stand-in is honest here.
class SocketFailure implements Exception {
  const SocketFailure();
}
