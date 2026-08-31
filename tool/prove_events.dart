/// `GET /api/events`, against a live nestwatch (0.4.0 or newer).
///
///   dart run tool/prove_events.dart --pin FP --password PW --real 8443
///
/// Everything about the parser is settled headlessly in `test/server_events_test.dart`,
/// including the keep-alive frame, whose exact bytes were read out of axum's source
/// (`Event::DEFAULT_KEEP_ALIVE` is the literal `":\n\n"`). What that cannot settle is
/// whether nestwatch, through the pinned client, over a real socket, actually sends what
/// this app is built to read — the framing, the tag vocabulary, and the fact that the
/// stream stays open rather than closing after the first frame.
///
/// Checks:
///
///   1. the stream opens and stays open, rather than being a one-shot response
///   2. an action on one connection is announced on another, within a second or two
///   3. approving announces BOTH subjects, because it changes the queue and the minutes
///   4. an unauthenticated connection is refused, so the stream is behind require_auth
library;

import 'dart:async';
import 'dart:io';

import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/api/server_events.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'dev_server.dart';
import 'harness.dart';

Future<void> main(List<String> argv) async {
  final args = parseArgs(argv, known: {'password', 'pin', 'real'});
  final port = int.parse(args['real'] ?? '8443');
  await requireListening(port, 'nestwatch');
  HttpOverrides.global = PinnedHttpOverrides(
    pin: Fingerprint.parse(requireArg(args, 'pin')),
  );

  final authority = '127.0.0.1:$port';
  final listener = await signInOrStop(authority, requireArg(args, 'password'));

  // A second signed-in client, because the point is that one connection hears about
  // what another one did. Sharing a client would prove far less.
  final actor = await signInOrStop(authority, requireArg(args, 'password'));

  // ------------------------------------------------- 1. it opens and stays open
  stdout.writeln('1. The stream opens and stays open');
  final heard = <String>[];
  final sub = listener.events().listen(
    heard.add,
    onError: (Object e) {
      stdout.writeln('   stream error: $e');
    },
  );
  // Long enough to cross axum's 15-second keep-alive, which is the frame that would
  // wrongly register as news if the parser treated comments as events.
  await Future<void>.delayed(const Duration(seconds: 17));
  check(
    heard.isEmpty,
    'a quiet house produces no events',
    'heard ${heard.length}: $heard',
  );

  // ------------------------------------------------- 2/3. an action is announced
  stdout.writeln('2. A change on one connection reaches another');
  // Make the change rather than wait for one. `submitAsChild` posts to the child's own
  // unauthenticated `/time-request`, which is how a request gets into the queue in real
  // life — so the two checks below run on every invocation instead of skipping whenever
  // nobody happens to have asked for minutes. An earlier version skipped them, which
  // meant the interesting half of this harness was the half that usually did not run.
  heard.clear();
  await submitAsChild(authority, 5, 'prove_events');
  await Future<void>.delayed(const Duration(seconds: 3));
  check(
    heard.contains('requests'),
    'a request arriving is announced to a listener that did not make it',
    'heard: $heard',
  );

  final pending = await actor.timeRequests();
  if (pending.isEmpty) {
    // The submission above should have produced one. If it did not, the announcement
    // check above has already failed and saying it twice adds nothing.
    skip('approving announces both subjects', 'nothing pending to approve');
  } else {
    heard.clear();
    await actor.approveTimeRequest(pending.first.id);
    await Future<void>.delayed(const Duration(seconds: 3));

    check(
      heard.contains(requestsSubject) && heard.contains(usageSubject),
      'approving announces both the queue and the minutes',
      'heard: $heard',
    );
  }

  // Order matters here, and both orders were measured against a live 0.4.0 rather than
  // guessed at.
  //
  // `await sub.cancel()` never returns while the stream is healthy: the server has no
  // reason to close an SSE connection, so the cancel waits on a socket the other end is
  // deliberately holding open. This harness hung there for ten minutes with every check
  // already passed.
  //
  // Cancelling first and then closing is worse than hanging. Closing the client destroys
  // the socket, the live stream raises `HttpException: Connection closed while receiving
  // data` — and the cancel has already detached the handler that would have caught it, so
  // it surfaces as an unhandled exception.
  //
  // So: close first, let the subscription's own onError take the closure, then cancel
  // without waiting.
  //
  // The app does not have this problem, and that was checked rather than assumed:
  // `ServerEvents` never cancels-then-closes. Its subscription keeps an `onError` for its
  // whole life, so a client closed underneath it — which is what `signOut` does — arrives
  // as an ordinary stream error and feeds the backoff, not the zone.
  listener.close();
  actor.close();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  unawaited(sub.cancel());

  // ------------------------------------------------- 4. it is behind require_auth
  stdout.writeln('3. The stream is not readable without a session');
  final anonymous = NestwatchClient(authority);
  try {
    await anonymous.events().first.timeout(const Duration(seconds: 5));
    check(
      false,
      'an unauthenticated stream is refused',
      'it delivered an event',
    );
  } on NestwatchException catch (e) {
    check(
      e.failure == NestwatchFailure.sessionExpired,
      'an unauthenticated stream is refused with 401',
      '${e.failure}',
    );
  } on TimeoutException {
    // Open but silent is not refused. nestwatch puts /api/events behind require_auth,
    // so this would mean the gate moved.
    check(
      false,
      'an unauthenticated stream is refused',
      'it stayed open and silent',
    );
  } finally {
    anonymous.close();
  }

  finish(
    'The event stream carries what this app is built to read: it stays open through '
    'a keep-alive, announces changes made on another connection, and refuses an '
    'unauthenticated reader.',
  );
}
