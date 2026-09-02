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
      async.elapse(const Duration(minutes: 30));
      final settled = opens;
      async.elapse(const Duration(minutes: 2));
      expect(opens, settled + 1, reason: 'capped at two minutes');

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
      expect(
        opens,
        2,
        reason: 'the wait grew, so one second is no longer enough',
      );
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
      expect(
        events.isReceiving,
        isFalse,
        reason: 'a closed stream delivers nothing',
      );
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
        onSessionLost: (e) => fatal = e,
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

  test('a PC too old to have the endpoint is not asked again', () {
    fakeAsync((async) {
      var opens = 0;
      Object? lost;
      final events = ServerEvents(
        open: () {
          opens++;
          // /api/events arrived in nestwatch 0.4.0. An older PC answers 404 forever, and
          // will not grow the route while this app is running — so retrying it is a
          // request every couple of minutes for the life of the app, against a server
          // that has already given its final answer.
          return Stream<String>.error(
            const NestwatchException(
              NestwatchFailure.unexpectedResponse,
              'That PC answered 404.',
            ),
          );
        },
        onChanged: (_) {},
        onSessionLost: (e) => lost = e,
      );
      events.start();
      async.flushMicrotasks();
      expect(opens, 1);
      async.elapse(const Duration(hours: 2));
      expect(opens, 1, reason: 'asked once, told no, stopped');

      // **And the parent stays signed in.**
      //
      // This is the assertion the old shape could not make. `onFatal` fired for both
      // permanent failures, the only caller wired it to `signOut()`, and so a 404 here
      // signed the parent out of a PC that answers every other route correctly. Because
      // `HomeScreen` re-mounts after the password is re-entered and starts the stream
      // again, that was not one sign-out — it was a loop with nothing to end it.
      expect(
        lost,
        isNull,
        reason:
            'a missing endpoint is not a lapsed session, and must not sign out',
      );
    });
  });

  test('the backoff cap stays above the poll it sits beside', () {
    // At 30s a switched-off PC was asked twice a minute — more traffic than the 60s poll
    // this was meant to relieve.
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
      async.elapse(const Duration(minutes: 30));
      final settled = opens;
      async.elapse(const Duration(seconds: 61));
      expect(
        opens - settled,
        lessThanOrEqualTo(1),
        reason: 'at most one reconnect per poll interval once backed off',
      );
      events.stop();
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
