/// Walking skeleton, step 2 (docs/PLAN.md §9): the pinned client, in the app.
///
/// Three screens come later. This build exists to make one property visible on a real
/// device: that every `dart:io` socket in the process is pinned, and that a wrong
/// certificate is refused during the handshake rather than after the request.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/pinning/fingerprint.dart';
import 'src/pinning/pinned_http_overrides.dart';

/// The process-wide pin.
///
/// Held here rather than inside a widget because [HttpOverrides.global] is set exactly
/// once, before any client exists, and the pin has to outlive every rebuild.
final pinnedOverrides = PinnedHttpOverrides();

void main() {
  // Before runApp, and before anything can touch `Image.network`'s lazily-initialised
  // static client -- which is the whole reason this works. See the class docs.
  HttpOverrides.global = pinnedOverrides;
  runApp(const NestwatchApp());
}

class NestwatchApp extends StatelessWidget {
  const NestwatchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Nestwatch',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E6F5E)),
    ),
    home: const PinProbePage(),
  );
}

/// A bare probe screen: enter the host and the fingerprint `nestwatch fingerprint`
/// printed, then hit `GET /session` -- which §5 picks as the first call precisely
/// because it is unauthenticated and LAN-gated, so it doubles as the pin probe and
/// reports `version` before anything secret is sent.
class PinProbePage extends StatefulWidget {
  const PinProbePage({super.key});

  @override
  State<PinProbePage> createState() => _PinProbePageState();
}

class _PinProbePageState extends State<PinProbePage> {
  final _host = TextEditingController(text: '192.168.0.78:8443');
  final _fp = TextEditingController();
  String? _result;
  bool _ok = false;
  bool _busy = false;

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _result = null;
    });

    try {
      pinnedOverrides.trust(Fingerprint.parse(_fp.text));
    } on FormatException catch (e) {
      setState(() {
        _busy = false;
        _ok = false;
        _result = 'That does not look like a fingerprint.\n${e.message}';
      });
      return;
    }

    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('https://${_host.text}/session'),
      );
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      setState(() {
        _ok = true;
        _result =
            'Connected, and the certificate matched.\n\n'
            'authenticated: ${json['authenticated']}\n'
            'version: ${json['version']}';
      });
    } on HandshakeException {
      // The pin refused. Nothing was sent -- the handshake never completed.
      final r = pinnedOverrides.lastRejection;
      setState(() {
        _ok = false;
        _result = r == null
            ? 'The TLS handshake failed.'
            : 'Refused: that PC presented a different certificate.\n\n'
                  'expected  ${r.expected}\n'
                  'presented ${r.observed}\n\n'
                  'If you just re-ran `nestwatch install`, re-scan the QR.\n'
                  'If you did not, something on your network may be impersonating it.';
      });
    } on SocketException catch (e) {
      setState(() {
        _ok = false;
        _result =
            'Could not reach ${_host.text}.\n${e.osError?.message ?? e.message}';
      });
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _fp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Nestwatch — pin probe')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'host:port',
                helperText: 'the address nestwatch install printed',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _fp,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'certificate SHA-256',
                helperText: 'run `nestwatch fingerprint` on that PC',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _probe,
              child: Text(_busy ? 'Connecting…' : 'GET /session'),
            ),
            if (_result != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _ok
                      ? theme.colorScheme.secondaryContainer
                      : theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  _result!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
