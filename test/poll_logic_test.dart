/// `pollOnce` against a real loopback server.
///
/// The seen-set arithmetic is unit-tested in `seen_requests_test.dart`; this covers the
/// order in which `pollOnce` does things, which is where the crash-safety property
/// lives and which no amount of set algebra can show.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/background/poll_logic.dart';
import 'package:nestwatch_mobile/src/background/seen_requests.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

import 'pinning_socket_test.dart' show fingerprintOf;

/// Records the order of calls, so "saved before notifying" is checkable.
class _RecordingStore implements SeenRequestStore {
  final List<String> log;
  Set<String> held;

  _RecordingStore(this.log, [Set<String>? initial]) : held = initial ?? {};

  @override
  Future<Set<String>> load() async {
    log.add('load');
    return held;
  }

  @override
  Future<void> save(Set<String> ids) async {
    log.add('save(${ids.length})');
    held = ids;
  }
}

void main() {
  const dir = 'test/fixtures';
  late HttpServer server;
  late NestwatchClient client;
  var body = '[]';

  setUp(() async {
    final context = SecurityContext()
      ..useCertificateChain('$dir/server.cert.pem')
      ..usePrivateKey('$dir/server.key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..write(body);
      await request.response.close();
    });
    HttpOverrides.global = PinnedHttpOverrides(
      pin: fingerprintOf('$dir/server.cert.pem'),
    );
    client = NestwatchClient('127.0.0.1:${server.port}');
  });

  tearDown(() async {
    client.close();
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  String request(String id) =>
      '{"id":"$id","ts":"2026-08-26T10:00:00Z","minutes":5,"reason":"r"}';

  test('the parent is announced to BEFORE the seen-set is persisted', () async {
    // This assertion was the other way round, defended by the belief that a failure
    // between the two would re-announce and that "told twice" is the worse outcome.
    // Re-announcing is what THIS ordering costs; the other one loses the request
    // outright, because `diffPending` marks every pending id seen and a `notify` that
    // throws then leaves `fresh` empty forever.
    body = '[${request("a")}]';
    final log = <String>[];
    final store = _RecordingStore(log);

    await pollOnce(
      client: client,
      store: store,
      notify: (r) async => log.add('notify(${r.length})'),
      cancel: (id) async => log.add('cancel($id)'),
    );

    expect(log, contains('notify(1)'));
    expect(
      log.indexOf('notify(1)'),
      lessThan(log.indexOf('save(1)')),
      reason: 'saving first loses the request entirely if notify throws',
    );
  });

  test(
    'a request announced but not recorded is announced again, not lost',
    () async {
      // The same property as the test above, but as behaviour rather than call order —
      // which is the one worth having. `[]` on the second poll would be a parent never
      // being told, silently, while a child waits.
      body = '[${request("a")}]';
      final store = _RecordingStore(<String>[]);

      await expectLater(
        pollOnce(
          client: client,
          store: store,
          notify: (_) async => throw const SocketException('channel down'),
          cancel: (_) async {},
        ),
        throwsA(isA<SocketException>()),
      );

      final announced = <int>[];
      await pollOnce(
        client: client,
        store: store,
        notify: (r) async => announced.add(r.length),
        cancel: (_) async {},
      );

      expect(
        announced,
        [1],
        reason:
            'a request whose announcement failed must not be silently dropped',
      );
    },
  );

  test('a second poll over the same queue announces nothing', () async {
    body = '[${request("a")}]';
    final log = <String>[];
    final store = _RecordingStore(log);
    final notified = <int>[];
    Future<bool> poll() => pollOnce(
      client: client,
      store: store,
      notify: (r) async => notified.add(r.length),
      cancel: (_) async {},
    );

    await poll();
    await poll();
    expect(notified, [1], reason: 'the second round had nothing new to say');
  });

  test(
    'a request that left the queue has its notification withdrawn',
    () async {
      body = '[${request("a")}]';
      final log = <String>[];
      final store = _RecordingStore(log);
      final cancelled = <String>[];
      Future<bool> poll() => pollOnce(
        client: client,
        store: store,
        notify: (_) async {},
        cancel: (id) async => cancelled.add(id),
      );

      await poll();
      body = '[]'; // resolved in the browser, or on another phone
      await poll();
      expect(cancelled, ['a']);
      expect(
        store.held,
        isEmpty,
        reason: 'and nothing lingers in the seen-set',
      );
    },
  );

  test('an unreachable server is silent, and not an error', () async {
    final unreachable = NestwatchClient(
      '127.0.0.1:1',
      timeout: const Duration(seconds: 2),
    );
    final notified = <List<TimeRequest>>[];
    final ok = await pollOnce(
      client: unreachable,
      store: InMemorySeenRequestStore(),
      notify: (r) async => notified.add(r),
      cancel: (_) async {},
    );
    // A "could not reach the PC" notification every 15 minutes while a parent is at
    // work is worse than silence, and returning false would ask for a retry storm.
    expect(ok, isTrue);
    expect(notified, isEmpty);
  });
}
