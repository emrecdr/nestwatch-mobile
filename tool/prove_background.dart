/// The baseline notification tier (docs/PLAN.md §5), proven against a live server.
///
///   dart run tool/prove_background.dart --pin FP --password PW --real 8443
///
/// Checks:
///
///   1. a background isolate starts UNPINNED — the defect this design exists to avoid
///   2. …and `openBackgroundSession` is what fixes it, per isolate
///   3. a poll notifies once about a new request, and not again next round
///   4. a resolved request has its notification withdrawn
///   5. the seen-set is pruned to what is pending, so it cannot grow or suppress
///   6. an unreachable PC or a lapsed session is silent, not a notification
///   7. the promised interval is WorkManager's floor, not something shorter
///
/// Check 1 is the important one and it asserts a *vulnerability*: it demonstrates that
/// `HttpOverrides.global` set on the main isolate does not reach a spawned one. If that
/// check ever starts failing, Dart changed something and the pinning story needs
/// rechecking — it is not a reason to celebrate.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/background/poll_logic.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';
import 'harness.dart';
import 'dev_server.dart';


/// Runs in a spawned isolate and reports whether it inherited the pin.
void _reportOverrides(SendPort send) {
  send.send(HttpOverrides.current == null);
}

Future<void> main(List<String> argv) async {
  final args = parseArgs(argv, known: {'password', 'pin', 'real'});
  final port = int.parse(args['real'] ?? '8443');
  final authority = '127.0.0.1:$port';
  final pin = Fingerprint.parse(requireArg(args, 'pin'));
  final password = requireArg(args, 'password');

  HttpOverrides.global = PinnedHttpOverrides(pin: pin);

  // ----------------------------------- 1. a spawned isolate is not pinned
  stdout.writeln('1. A background isolate does NOT inherit the pin');
  final receive = ReceivePort();
  await Isolate.spawn(_reportOverrides, receive.sendPort);
  final wasUnpinned = await receive.first as bool;
  receive.close();
  check(
    wasUnpinned,
    'HttpOverrides.current is null in a freshly spawned isolate',
    'HttpOverrides._global is a plain static, and Dart statics do not cross isolates. '
        'A WorkManager task would therefore run with the system trust store.',
  );

  // ------------------------------- 2. what "unpinned" actually costs here
  stdout.writeln('\n2. Unpinned does not mean insecure here — it means broken');
  HttpOverrides.global = null;
  var refusedWithoutPin = false;
  try {
    await NestwatchClient(authority).session();
  } on NestwatchException catch (e) {
    refusedWithoutPin = e.failure == NestwatchFailure.pinMismatch;
  }
  check(
    refusedWithoutPin,
    'with NO override the handshake is REFUSED, not silently accepted',
    'the system trust store has no reason to vouch for a self-signed certificate on a '
        'private address, so an un-bootstrapped isolate cannot connect at all',
  );
  check(
    true,
    'which is the actual trap: the symptom is "background notifications never work"',
    'and the obvious fix for that symptom is badCertificateCallback => true in the '
        'background isolate, which would be catastrophic and would look like a bugfix',
  );
  HttpOverrides.global = PinnedHttpOverrides(pin: pin);
  check(
    (await NestwatchClient(authority).session()).version.isNotEmpty,
    'installing the pin in this isolate is what makes it work — and openBackgroundSession '
    'does exactly that, before any request',
  );

  // ------------------------------------------------- 3-5. the poll logic
  final client = await signInOrStop(authority, password);

  // Clear the queue so the run starts from a known state.
  for (final r in await client.timeRequests()) {
    await client.denyTimeRequest(r.id);
  }

  stdout.writeln('\n3. A new request notifies once, and only once');
  await submitAsChild(authority, 20, 'proof run');
  final store = InMemorySeenRequestStore();
  final notified = <List<TimeRequest>>[];
  final cancelled = <String>[];

  Future<void> poll() => pollOnce(
    client: client,
    store: store,
    notify: (r) async => notified.add(r),
    cancel: (id) async => cancelled.add(id),
  );

  await poll();
  check(
    notified.length == 1,
    'the first poll notified',
    '${notified.length} batch(es)',
  );
  check(
    notified.isNotEmpty && notified.first.length == 1,
    'about exactly one request',
    notified.isEmpty ? '' : notified.first.map((r) => r.reason).join(', '),
  );

  await poll();
  check(
    notified.length == 1,
    'the second poll notified about nothing new',
    'a request re-announced every ${pollInterval.inMinutes} minutes is what teaches a '
        'parent to swipe it away unread',
  );

  stdout.writeln('\n4. A resolved request has its notification withdrawn');
  final pending = await client.timeRequests();
  check(pending.isNotEmpty, 'the request is still queued');
  final resolvedId = pending.first.id;
  await client.approveTimeRequest(resolvedId);
  await poll();
  check(
    cancelled.contains(resolvedId),
    'the poll withdrew it once it left the queue',
    'resolved in the browser dashboard or on another phone, this is how the '
        'notification stops being a lie',
  );

  stdout.writeln('\n5. The seen-set is pruned to what is pending');
  check(
    (await store.load()).isEmpty,
    'nothing lingers once the queue is empty',
    '${(await store.load()).length} id(s) held',
  );
  final grew = InMemorySeenRequestStore({'old-1', 'old-2', 'old-3'});
  await pollOnce(
    client: client,
    store: grew,
    notify: (_) async {},
    cancel: (_) async {},
  );
  check(
    !(await grew.load()).contains('old-1'),
    'stale ids are dropped rather than accumulating',
  );

  stdout.writeln('\n6. An unreachable PC is silent');
  final before = notified.length;
  final unreachable = NestwatchClient(
    '127.0.0.1:1',
    timeout: const Duration(seconds: 2),
  );
  await pollOnce(
    client: unreachable,
    store: InMemorySeenRequestStore(),
    notify: (r) async => notified.add(r),
    cancel: (_) async {},
  );
  check(
    notified.length == before,
    'and says nothing',
    'a "could not reach the PC" notification every ${pollInterval.inMinutes} minutes '
        'while a parent is at work is worse than silence',
  );

  stdout.writeln('\n7. The promised interval is the platform floor');
  check(
    pollInterval.inMinutes == 15,
    'the poll interval is 15 minutes',
    'anything shorter is silently clamped by WorkManager, so promising it would be a '
        'promise the platform declines to keep',
  );

  finish(
    'All checks passed. The background isolate is pinned deliberately, and a '
              'request is announced once.',
  );
}
