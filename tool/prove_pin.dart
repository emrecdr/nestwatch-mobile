/// Walking-skeleton step 2: the pinned client, proven by refusal.
///
/// Run against a live nestwatch (see docs/PLAN.md §0), never a mock:
///
///   dart run tool/prove_pin.dart \
///     --pin `nestwatch fingerprint` --real 8443 --impostor 8444 --sink 9443
///
/// Four checks, in the order that makes each one mean something:
///   1. the pinned client reaches the real server            (the pin admits the right cert)
///   2. it refuses a different server on the same LAN        (the pin excludes a wrong one)
///   3. nothing crossed the wire when it refused             (refusal precedes the body)
///   4. the wire check can see bytes when they do flow       (check 3 was not vacuous)
///
/// Check 4 is the one that keeps this honest. A rig that reports "no bytes" because it
/// is broken would pass check 3 against any implementation, including the late-checking
/// one §2 warns about.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';
import 'package:nestwatch_mobile/src/pinning/pinned_http_overrides.dart';

/// Recognisable bytes to look for on the wire. If this string ever shows up in the
/// sink's log while the wrong certificate is pinned, the pin let a request body out.
const _marker = 'THIS-BODY-MUST-NEVER-REACH-AN-IMPOSTOR';

int _failures = 0;

void _check(bool ok, String label, [String detail = '']) {
  final mark = ok ? 'PASS' : 'FAIL';
  stdout.writeln(
    '  [$mark] $label${detail.isEmpty ? '' : '\n         $detail'}',
  );
  if (!ok) _failures++;
}

Future<void> main(List<String> argv) async {
  final args = <String, String>{};
  for (var i = 0; i < argv.length - 1; i += 2) {
    args[argv[i].replaceFirst('--', '')] = argv[i + 1];
  }

  final pin = Fingerprint.parse(args['pin']!);
  final realPort = int.parse(args['real'] ?? '8443');
  final impostorPort = int.parse(args['impostor'] ?? '8444');
  final sinkPort = int.parse(args['sink'] ?? '9443');

  final overrides = PinnedHttpOverrides(pin: pin);
  // The one line that pins the whole process. In the app this sits at the top of
  // main(), before runApp() and before anything can touch Image.network's static.
  HttpOverrides.global = overrides;

  stdout.writeln('Pinned to $pin\n');
  // Preflight the sink before trusting anything it says.
  //
  // Its log is the evidence for check 3, and an ABSENT log is indistinguishable from
  // "no bytes crossed the wire" -- it reads as a pass. That happened: a leftover sink
  // from an earlier run still owned the port, the new one died on bind, and check 3
  // passed on an empty file. Check 4 caught it, which is what check 4 is for; this
  // stops it being a puzzle in the first place.
  final sinkLog = File('/tmp/nestwatch-sink.log');
  final sinkLines = sinkLog.existsSync()
      ? sinkLog.readAsLinesSync()
      : <String>[];
  if (!sinkLines.any((l) => l.contains('"listening"'))) {
    stdout.writeln(
      '  [STOP] The byte-counting sink is not listening on port $sinkPort.\n'
      '         ${sinkLines.isEmpty ? "Its log is empty or missing." : sinkLines.last}\n'
      '         Start it first (see README), and check nothing else owns that port:\n'
      '           lsof -ti :$sinkPort | xargs kill',
    );
    exit(2);
  }

  // ---------------------------------------------------------------- 1. admits
  stdout.writeln('1. The pinned client reaches the real server');
  try {
    final body = await _get('https://127.0.0.1:$realPort/session');
    final json = jsonDecode(body) as Map<String, dynamic>;
    _check(
      json.containsKey('authenticated') && json.containsKey('version'),
      'GET /session over the pinned client',
      'server said: $body',
    );
  } on Object catch (e) {
    _check(false, 'GET /session over the pinned client', 'threw: $e');
  }

  // -------------------------------------------------------------- 2. excludes
  stdout.writeln('\n2. It refuses a different certificate on the same LAN');
  try {
    await _get('https://127.0.0.1:$impostorPort/session');
    _check(
      false,
      'impostor refused',
      'the request SUCCEEDED — the pin is not holding',
    );
  } on HandshakeException catch (e) {
    final r = overrides.rejectionFor('127.0.0.1:$impostorPort');
    _check(
      true,
      'impostor refused with HandshakeException',
      '${e.message.split(':').first}; presented ${r?.observed}',
    );
    _check(
      r != null && !r.observed.matches(pin.bytes),
      'the refusal recorded a fingerprint, and it differs from the pin',
    );
  } on Object catch (e) {
    _check(
      false,
      'impostor refused with HandshakeException',
      'threw the wrong type: ${e.runtimeType}: $e',
    );
  }

  // ------------------------------------------------------- 3. nothing on wire
  stdout.writeln('\n3. Nothing crossed the wire when it refused');
  final refused = await _sinkAttempt(overrides, sinkPort, expectAccept: false);
  _check(
    refused.handshakeFailed,
    'the sink saw the handshake fail',
    refused.events.join('\n         '),
  );
  _check(refused.appBytes == 0, 'the sink received 0 application bytes');
  _check(!refused.sawMarker, 'the request body never reached the impostor');

  // ------------------------------------------------ 4. the rig is not vacuous
  stdout.writeln(
    '\n4. Control — the same rig DOES see a body when the pin admits',
  );
  final admitted = await _sinkAttempt(overrides, sinkPort, expectAccept: true);
  _check(
    admitted.handshakeOk,
    'handshake completed once the sink cert was pinned',
  );
  _check(
    admitted.appBytes > 0,
    'the sink received ${admitted.appBytes} application bytes',
  );
  _check(
    admitted.sawMarker,
    'and the marker header was in them — so check 3 was a real observation',
  );

  stdout.writeln('\n${'-' * 68}');
  stdout.writeln(
    _failures == 0
        ? 'All checks passed. The pin refuses a wrong certificate before any body is sent.'
        : '$_failures check(s) FAILED.',
  );
  exit(_failures == 0 ? 0 : 1);
}

Future<String> _get(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    return await res.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// One attempt against the byte-counting sink, reading back what it observed.
Future<_SinkResult> _sinkAttempt(
  PinnedHttpOverrides overrides,
  int port, {
  required bool expectAccept,
}) async {
  final saved = overrides.pin!;

  if (expectAccept) {
    // Pin the sink's own certificate, so the handshake completes and the body flows.
    overrides.trust(await _sinkFingerprint(port));
  }

  final marker = File('/tmp/nestwatch-sink.log');
  final before = marker.existsSync() ? marker.readAsLinesSync().length : 0;

  try {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('https://127.0.0.1:$port/api/probe'),
      );
      req.headers.add('X-Nestwatch-Proof', _marker);
      req.write('{"secret":"$_marker"}');
      final res = await req.close();
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  } on Object {
    // Expected in the refusal case.
  }

  overrides.trust(saved);

  // Give the sink a moment to flush its lines.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final lines = marker.existsSync()
      ? marker.readAsLinesSync().skip(before).toList()
      : <String>[];
  return _SinkResult(lines);
}

Future<Fingerprint> _sinkFingerprint(int port) async {
  final pem = File('/tmp/nestwatch-impostor/cert.pem').readAsStringSync();
  // The sink presents the impostor cert; hash its DER exactly as cert::fingerprint does.
  final b64 = pem
      .split('\n')
      .where((l) => !l.startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), '');
  final der = base64.decode(b64);
  return Fingerprint.fromBytes(sha256.convert(der).bytes);
}

/// What the sink observed during one attempt.
///
/// Decoded as JSON rather than pattern-matched: the first version of this scanned for
/// the literal `"event":"app_bytes"` and read 0 bytes off a line that plainly said
/// 255, because the emitter writes `"event": "app_bytes"` with a space. Check 4 exists
/// to catch exactly that class of mistake, and it did.
class _SinkResult {
  final List<String> events;
  final List<Map<String, dynamic>> _parsed;

  _SinkResult(this.events)
    : _parsed = events.map((l) {
        try {
          return jsonDecode(l) as Map<String, dynamic>;
        } on FormatException {
          return <String, dynamic>{};
        }
      }).toList();

  bool _has(String event) => _parsed.any((e) => e['event'] == event);

  bool get handshakeFailed => _has('handshake_failed');
  bool get handshakeOk => _has('handshake_ok');
  bool get sawMarker => events.any((l) => l.contains(_marker));

  int get appBytes {
    for (final e in _parsed) {
      if (e['event'] == 'app_bytes') return (e['n'] as num).toInt();
    }
    return 0;
  }
}
