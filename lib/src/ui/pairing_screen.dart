/// The screen that drives the pairing state machine.
library;

import 'package:flutter/material.dart';

import '../api/nestwatch_api.dart';
import '../pairing/pair_invite.dart';
import '../pairing/pairing_controller.dart';
import '../pairing/server_identity.dart';
import '../pinning/fingerprint.dart';
import 'fingerprint_view.dart';
import 'scan_screen.dart';

class PairingScreen extends StatefulWidget {
  final PairingController controller;
  const PairingScreen({super.key, required this.controller});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  Future<void> _scan() async {
    final payload = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (payload == null || !mounted) return;
    await widget.controller.beginFromQrPayload(payload);
  }

  Future<void> _enterAddress() async {
    final invite = await showDialog<PairInvite>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (invite == null || !mounted) return;
    await widget.controller.begin(invite);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Nestwatch'),
      actions: [
        if (widget.controller.current != null)
          IconButton(
            tooltip: 'Forget this PC',
            icon: const Icon(Icons.link_off),
            onPressed: widget.controller.unpair,
          ),
      ],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _body(context),
    ),
  );

  Widget _body(BuildContext context) => switch (widget.controller.state) {
    PairingIdle() => _idle(context),
    PairingBusy(:final what) => _busy(what),
    PairingNeedsFingerprintCheck(:final invite, :final observed) =>
      _confirmFirstUse(context, invite, observed),
    PairingSucceeded(:final identity, :final session) => _succeeded(
      context,
      identity,
      session,
    ),
    PairingRefused(:final rejection, :final explanation) => _refused(
      context,
      explanation,
      rejection.observed,
      rejection.expected,
    ),
    PairingFailed(:final message) => _failed(context, message),
  };

  // ------------------------------------------------------------------ states

  Widget _idle(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Connect to the PC you want to watch',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      const Text(
        'Run `nestwatch install` (or `nestwatch pair`) on that PC. It prints a QR code.',
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _scan,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan the pairing code'),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _enterAddress,
        child: const Text('Type the address instead'),
      ),
      if (widget.controller.current case final paired?) ...[
        const Divider(height: 40),
        _pairedSummary(context, paired),
      ],
    ],
  );

  Widget _busy(String what) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60),
    child: Column(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Text(what),
      ],
    ),
  );

  /// Trust on first use. Nothing is trusted while this is on screen.
  Widget _confirmFirstUse(
    BuildContext context,
    PairInvite invite,
    Fingerprint observed,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            'This connection is not verified yet.\n\n'
            'The pairing code from ${invite.authority} did not include the PC\'s '
            'certificate fingerprint, so this app has no way to tell on its own whether '
            'the certificate below really belongs to your PC.',
            style: TextStyle(color: scheme.onTertiaryContainer),
          ),
        ),
        const SizedBox(height: 20),
        Text('On that PC, run:', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        const SelectableText(
          'nestwatch fingerprint',
          style: TextStyle(fontFamily: 'monospace', fontSize: 15),
        ),
        const SizedBox(height: 16),
        const Text('It must print exactly this:'),
        const SizedBox(height: 10),
        FingerprintView(observed),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: widget.controller.confirmFirstUse,
          child: const Text('It matches — trust this PC'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: widget.controller.rejectFirstUse,
          child: const Text('It does not match'),
        ),
        const SizedBox(height: 16),
        Text(
          'Compare every group, not just the beginning. An impostor can make a '
          'certificate whose fingerprint starts the same way.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _succeeded(
    BuildContext context,
    ServerIdentity identity,
    SessionInfo session,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Icon(Icons.lock, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Connected to ${identity.authority}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _pairedSummary(context, identity),
      const SizedBox(height: 16),
      Text(
        'nestwatch ${session.version} · '
        '${session.authenticated ? "signed in" : "not signed in yet"}',
      ),
      const SizedBox(height: 24),
      const Text(
        'Signing in and the three screens come next — this build stops at proving the '
        'connection is pinned.',
      ),
    ],
  );

  Widget _refused(
    BuildContext context,
    String explanation,
    Fingerprint observed,
    Fingerprint? expected,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            explanation,
            style: TextStyle(color: scheme.onErrorContainer),
          ),
        ),
        const SizedBox(height: 20),
        Text('It presented:', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        FingerprintView(observed),
        if (expected != null) ...[
          const SizedBox(height: 16),
          Text(
            'This app expected:',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          FingerprintView(expected),
        ],
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: widget.controller.reset,
          child: const Text('Back'),
        ),
      ],
    );
  }

  Widget _failed(BuildContext context, String message) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
      ),
      const SizedBox(height: 20),
      OutlinedButton(
        onPressed: widget.controller.reset,
        child: const Text('Try again'),
      ),
    ],
  );

  /// Provenance, stated every time rather than only at pairing.
  Widget _pairedSummary(BuildContext context, ServerIdentity identity) {
    final verified = identity.provenance.isVerified;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              verified ? Icons.verified_user : Icons.help_outline,
              size: 18,
              color: verified ? scheme.primary : scheme.tertiary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                verified
                    ? 'Verified from the pairing code'
                    : 'Trusted on first use — you compared this by eye',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FingerprintView(identity.fingerprint),
      ],
    );
  }
}

/// Manual address entry, for a QR that has expired or a phone that cannot scan.
///
/// There is no token behind a typed address, which is the same position a spent token
/// leaves the app in (trap 3) — §5 sends both to password login.
class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _text.text.trim().replaceFirst(RegExp(r'^https?://'), '');
    if (raw.isEmpty) {
      setState(() => _error = 'Enter the address nestwatch printed.');
      return;
    }
    final parts = raw.split(':');
    final host = parts.first;
    // An address typed without a port must NOT fall through to https's default of 443 —
    // that produces "unreachable" for what is really a missing port.
    final port = parts.length > 1
        ? int.tryParse(parts[1])
        : nestwatchDefaultPort;
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      setState(() => _error = 'That does not look like host:port.');
      return;
    }
    Navigator.of(context).pop(PairInvite.manual(host: host, port: port));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Type the address'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _text,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '192.168.0.78:$nestwatchDefaultPort',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        const Text(
          'Without a pairing code you will be asked for the control password instead.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Connect')),
    ],
  );
}
