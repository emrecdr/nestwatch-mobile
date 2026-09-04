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
import 'package:nestwatch_mobile/src/background/sign_in_notice.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

import 'support/certs.dart';

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

  @override
  Future<void> clear() async {
    log.add('clear');
    held = const {};
  }
}

void main() {
  const dir = fixtureDir;
  late HttpServer server;
  late NestwatchClient client;
  var body = '[]';

  /// What the stub answers with. 200 unless a test is about a refusal; reset in
  /// `tearDown` so a status set by one test cannot leak into the next.
  var status = 200;

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
        ..statusCode = status
        ..write(body);
      await request.response.close();
    });
    HttpOverrides.global = PinnedHttpOverrides(
      pin: fingerprintOf('$dir/server.cert.pem'),
    );
    client = NestwatchClient('127.0.0.1:${server.port}');
  });

  tearDown(() async {
    status = 200;
    body = '[]';
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
      signInNotice: SignInNotice.recording(),
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
          signInNotice: SignInNotice.recording(),
        ),
        throwsA(isA<SocketException>()),
      );

      final announced = <int>[];
      await pollOnce(
        client: client,
        store: store,
        notify: (r) async => announced.add(r.length),
        cancel: (_) async {},
        signInNotice: SignInNotice.recording(),
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
    Future<void> poll() => pollOnce(
      client: client,
      store: store,
      notify: (r) async => notified.add(r.length),
      cancel: (_) async {},
      signInNotice: SignInNotice.recording(),
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
      Future<void> poll() => pollOnce(
        client: client,
        store: store,
        notify: (_) async {},
        cancel: (id) async => cancelled.add(id),
        signInNotice: SignInNotice.recording(),
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
    final quiet = <String>[];
    await pollOnce(
      client: unreachable,
      store: InMemorySeenRequestStore(),
      notify: (r) async => notified.add(r),
      cancel: (_) async {},
      signInNotice: SignInNotice.recording(quiet),
    );
    // A "could not reach the PC" notification every 15 minutes while a parent is at
    // work is worse than silence. Silence is the whole assertion: an unreachable PC
    // must produce no notification and no throw.
    expect(notified, isEmpty);
    // And that survived the sign-in notice being added beside it. `unreachable` is
    // transient and fixes itself when the phone comes home; only `sessionExpired` is
    // permanent and needs the parent to do something.
    expect(quiet, isEmpty);
  });

  group('a sign-in that has ended is not a PC out of reach', () {
    // ## What changed underneath this
    //
    // Until nestwatch 0.7.0 a polled session could not lapse: the idle window slid
    // forward on every request, so an installed app refreshed its own session forever
    // and a lapsed session in the background was very nearly unreachable as a state.
    // 0.7.0 added `SESSION_MAX_DAYS`, an absolute ceiling measured from `first_seen`
    // that activity does not move -- so every paired phone now loses its session exactly
    // one month after pairing, guaranteed, and the silence above would have been this
    // app's entire answer to it.

    test(
      'a lapsed sign-in is announced, because silence reads as "nobody asked"',
      () async {
        status = 401;
        body = '';
        final log = <String>[];

        await pollOnce(
          client: client,
          store: InMemorySeenRequestStore(),
          notify: (_) async {},
          cancel: (_) async {},
          signInNotice: SignInNotice.recording(log),
        );

        expect(log, [SignInNotice.raised]);
      },
    );

    test('a bare 403 -- not on the LAN -- stays silent', () async {
      // `require_lan_peer` answers a bare 403 with an empty body, which is what being at
      // work looks like from here. Distinct from the unreachable case above: that one is
      // a dead socket, this one is a live server refusing. Both are transient, both must
      // stay quiet, and they arrive as different failures so both need saying.
      status = 403;
      body = '';
      final log = <String>[];

      await pollOnce(
        client: client,
        store: InMemorySeenRequestStore(),
        notify: (_) async {},
        cancel: (_) async {},
        signInNotice: SignInNotice.recording(log),
      );

      expect(log, isEmpty);
    });

    test('the parent is told once, not every fifteen minutes', () async {
      // The whole reason a stored flag exists rather than just a notification id. A poll
      // runs every fifteen minutes and a lapsed session stays lapsed until somebody types
      // a password, so "announce whenever it fails" is ninety-six alerts a day.
      status = 401;
      body = '';
      final log = <String>[];
      final notice = SignInNotice.recording(log);

      for (var round = 0; round < 4; round++) {
        await pollOnce(
          client: client,
          store: InMemorySeenRequestStore(),
          notify: (_) async {},
          cancel: (_) async {},
          signInNotice: notice,
        );
      }

      expect(log, [SignInNotice.raised]);
    });

    test('and it is taken down once the session works again', () async {
      status = 401;
      body = '';
      final log = <String>[];
      final notice = SignInNotice.recording(log);

      await pollOnce(
        client: client,
        store: InMemorySeenRequestStore(),
        notify: (_) async {},
        cancel: (_) async {},
        signInNotice: notice,
      );

      // The parent signed in again, or re-paired.
      status = 200;
      body = '[]';
      await pollOnce(
        client: client,
        store: InMemorySeenRequestStore(),
        notify: (_) async {},
        cancel: (_) async {},
        signInNotice: notice,
      );

      expect(log, [SignInNotice.raised, SignInNotice.lowered]);
    });

    test('a session that never lapsed withdraws nothing', () async {
      // `lower()` runs on every successful poll, so it has to be free when there is
      // nothing to take down -- otherwise the ordinary path cancels a notification that
      // was never posted, four times an hour, forever.
      status = 200;
      body = '[]';
      final log = <String>[];

      await pollOnce(
        client: client,
        store: InMemorySeenRequestStore(),
        notify: (_) async {},
        cancel: (_) async {},
        signInNotice: SignInNotice.recording(log),
      );

      expect(log, isEmpty);
    });
  });
}
