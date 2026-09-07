/// Which devices are signed in to that PC, and signing one out.
///
/// ## Why this is a pushed screen and not a fifth tab
///
/// `PLAN.md` §5 holds the tab bar to the things a parent opens the app *for*. This is not
/// one of them: it is reached when something has gone wrong or been lost — a phone left at
/// a friend's house, a laptop sold, a pairing code that went to the wrong person. It sits
/// behind the identity dialog beside *Privacy* and *Forget this PC*, which is where the
/// other "what does this app trust, and can I take it back" controls already live.
///
/// ## The handle is an address with a short life
///
/// Every row is keyed by a twelve-character salted hash of the session id, never the id.
/// nestwatch salts it **per process**, and says so: *"handles change when the service
/// restarts."* So nothing here may be persisted, and a list that has been on screen while
/// that PC rebooted is entirely stale — every row in it answers 404. That is why a failed
/// revoke re-reads instead of complaining, and why this screen has no cache.
///
/// ## Signing yourself out is allowed, and it ends here
///
/// nestwatch permits it on purpose: refusing "would mean the one device a parent is
/// definitely holding is the one they cannot clear". Measured on 2026-09-07 — the call
/// answers `was_current: true` and the next request on that cookie is a 401. So this screen
/// does not try to carry on: it hands back to the pairing flow the same way a lapsed
/// sign-in does, because that is exactly what it now is.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/nestwatch_api.dart';
import 'notice.dart';
import 'relative_time.dart';
import 'screen_load.dart';

class SessionsScreen extends StatefulWidget {
  final NestwatchClient client;

  /// Called when this phone's own session is the one that ended — by revoking itself, or
  /// by any other 401. Wired to the same `signOut` every other screen hands 401s to, so
  /// there is one way back to the password prompt rather than two.
  final VoidCallback onSessionEnded;

  const SessionsScreen({
    super.key,
    required this.client,
    required this.onSessionEnded,
  });

  static Route<void> route({
    required NestwatchClient client,
    required VoidCallback onSessionEnded,
  }) => MaterialPageRoute<void>(
    builder: (_) =>
        SessionsScreen(client: client, onSessionEnded: onSessionEnded),
  );

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<SessionDevice>? _devices;
  String? _error;

  /// Handles with a revoke in flight, so one row cannot be double-tapped.
  final _revoking = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// No poller, deliberately. This is a screen a parent opens, reads and acts on; polling
  /// it would re-fetch a list whose rows they may be part-way through deciding about, and
  /// the one thing that changes it while it is open is an action taken here.
  Future<void> _load() async {
    final outcome = await loadOnce(widget.client.sessions);
    if (!mounted) return;
    switch (outcome) {
      case Loaded(data: final devices):
        setState(() {
          _devices = devices;
          _error = null;
        });
      case Failed(:final message):
        setState(() => _error = message);
      case HandedBack():
        widget.onSessionEnded();
    }
  }

  Future<void> _revoke(SessionDevice device) async {
    if (!_revoking.add(device.handle)) return;
    setState(() {});
    try {
      final outcome = await widget.client.revokeSession(device.handle);
      if (!mounted) return;
      if (outcome.wasCurrent) {
        // The cookie is already dead — measured, the next request 401s. Leaving the screen
        // up would show a list that cannot be refreshed, so this ends here.
        widget.onSessionEnded();
        Navigator.of(context).maybePop();
        return;
      }
      _snack(
        outcome.acted
            ? 'Signed out. That device has to sign in again to see anything.'
            // A 404. Somebody else got there first, or that PC restarted and every handle
            // in this list changed. Both are ordinary and neither is this parent's problem.
            : 'That device was already signed out.',
      );
    } on NestwatchException catch (e) {
      if (!mounted) return;
      if (e.failure == NestwatchFailure.sessionExpired) {
        widget.onSessionEnded();
        return;
      }
      _snack(e.message);
    } finally {
      _revoking.remove(device.handle);
      // Re-read either way. After a revoke the list has changed; after a failure it is the
      // thing most likely to explain why.
      if (mounted) await _load();
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _confirm(SessionDevice device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          device.current ? 'Sign this phone out?' : 'Sign that device out?',
        ),
        content: Text(
          device.current
              // The one row where the consequence lands on the person tapping it. Said
              // plainly rather than hedged, because the alternative — refusing — would
              // leave the device a parent is definitely holding as the one they cannot
              // clear, which is the case nestwatch allows this for.
              ? 'This is the phone you are holding. You will be signed out here and '
                    'have to enter the control password again. The PC stays paired, so '
                    'there is nothing to re-scan.'
              : 'It will have to sign in again with the control password before it can '
                    'see anything or answer a request. Nothing about the PC changes, and '
                    'this phone is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _revoke(device);
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    return Scaffold(
      appBar: AppBar(title: const Text('Signed-in devices')),
      body: SafeArea(
        top: false,
        child: devices == null ? _waiting() : _list(devices),
      ),
    );
  }

  Widget _waiting() {
    final message = _error;
    if (message == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }

  Widget _list(List<SessionDevice> devices) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        const Notice(
          'Every device here can see your child\'s screen and answer their '
          'requests. Signing one out does not change anything on the PC itself.',
        ),
        const SizedBox(height: 16),
        // Order is the server's — newest first, so a device that has just appeared is at
        // the top. That is the one a parent is looking for after a scare, and re-sorting
        // here would be this app deciding otherwise.
        for (final device in devices) _row(context, device),
        if (devices.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: Text('Nothing is signed in.')),
          ),
      ],
    ),
  );

  Widget _row(BuildContext context, SessionDevice device) {
    final theme = Theme.of(context);
    final busy = _revoking.contains(device.handle);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Rendered as plain text, never as anything that interprets it: this
                    // is a header a client chose, and nestwatch takes the same care on its
                    // own card. Null is a session older than device-remembering, and is
                    // said rather than left blank.
                    device.userAgent ?? 'A device that did not say what it is',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _subtitle(device),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: busy ? null : () => _confirm(device),
              child: Text(busy ? '…' : 'Sign out'),
            ),
          ],
        ),
      ),
    );
  }

  /// The second line: which device this is, and how recently it was about.
  ///
  /// `lastSeenPhrase` rather than `ago`, and the difference is load-bearing — see its own
  /// doc. The figure behind it is accurate to about a week, so it is rendered at about a
  /// week.
  String _subtitle(SessionDevice device) {
    final parts = <String>[
      if (device.current) 'This phone',
      lastSeenPhrase(
        DateTime.fromMillisecondsSinceEpoch(
          device.lastSeenEpoch * 1000,
        ).toLocal(),
      ),
      // Only worth naming when it is not the ordinary one. Every parent pairing is a
      // dashboard scope, so printing it on every row would be noise; an integration is the
      // exception and is exactly what somebody scanning this list wants to spot.
      if (device.scopeKind == 'integration')
        'Integration${device.scopeSource == null ? '' : ' · ${device.scopeSource}'}',
    ];
    return parts.join(' · ');
  }
}
