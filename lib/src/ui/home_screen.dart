/// Four screens.
///
/// PLAN.md §5 said "three, and only three", and kept rules, routines, curfew and the
/// audit log in the browser: "configuration, done rarely, and each one added is a second
/// interface to keep in step with 24 routes forever."
///
/// Time codes are the fourth, and the exception is deliberate. That test is really about
/// *where the parent is* when they need the thing — and a time code is used **because**
/// you are away from the browser. The phone is not a worse dashboard for that task, it is
/// the only thing in reach. §7 calls away-from-home support impossible, which holds for
/// notification but not for this: nestwatch already solved it offline, and the app was
/// simply not surfacing it.
///
/// The tabs are built with an [IndexedStack] rather than a `TabBarView` so each screen
/// keeps its state across switches — but each is told whether it is `visible`, and stops
/// its own polling when it is not. Keeping a screen alive is not the same as letting it
/// keep asking the PC for frames.
library;

import 'package:flutter/material.dart';

import '../api/nestwatch_api.dart';
import '../pairing/pairing_controller.dart';
import '../pairing/server_identity.dart';
import 'notifications_sheet.dart';
import 'screenshot_screen.dart';
import 'time_codes_screen.dart';
import 'time_requests_screen.dart';
import 'usage_screen.dart';

class HomeScreen extends StatefulWidget {
  final PairingController controller;
  final NestwatchClient client;
  final ServerIdentity identity;

  const HomeScreen({
    super.key,
    required this.controller,
    required this.client,
    required this.identity,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  /// A 401 from any `/api/*` path means the session lapsed.
  ///
  /// §5 is explicit that this is not a re-pair: the certificate is still trusted and the
  /// pin still holds; only the session went. Handing back to the controller puts the
  /// password prompt up without disturbing the pin.
  void _onFailure(NestwatchException e) {
    if (e.failure != NestwatchFailure.sessionExpired) return;
    widget.controller.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final verified = widget.identity.provenance.isVerified;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.identity.authority),
        titleTextStyle: Theme.of(context).textTheme.titleMedium,
        actions: [
          IconButton(
            tooltip: verified
                ? 'Verified from the pairing code'
                : 'Trusted on first use — you compared this by eye',
            icon: Icon(
              verified ? Icons.verified_user : Icons.help_outline,
              size: 20,
            ),
            onPressed: () => _showIdentity(context),
          ),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: false,
              builder: (_) =>
                  NotificationsSheet(authority: widget.identity.authority),
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: widget.controller.signOut,
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          TimeRequestsScreen(
            client: widget.client,
            visible: _tab == 0,
            onFailure: _onFailure,
          ),
          UsageScreen(
            client: widget.client,
            visible: _tab == 1,
            onFailure: _onFailure,
          ),
          ScreenshotScreen(
            client: widget.client,
            visible: _tab == 2,
            onFailure: _onFailure,
          ),
          TimeCodesScreen(
            client: widget.client,
            visible: _tab == 3,
            onFailure: _onFailure,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.more_time), label: 'Requests'),
          NavigationDestination(icon: Icon(Icons.timelapse), label: 'Today'),
          NavigationDestination(
            icon: Icon(Icons.desktop_windows),
            label: 'Screen',
          ),
          NavigationDestination(icon: Icon(Icons.key), label: 'Codes'),
        ],
      ),
    );
  }

  /// Provenance again, on demand. Shown here as well as at pairing because a warning
  /// given once and never repeated stops being a warning.
  void _showIdentity(BuildContext context) {
    final identity = widget.identity;
    final verified = identity.provenance.isVerified;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(verified ? 'Verified PC' : 'Trusted on first use'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              verified
                  ? 'The pairing code carried this PC\'s certificate fingerprint, so it '
                        'was checked before this app ever connected.'
                  : 'The pairing code did not carry a fingerprint, so this app learned '
                        'it from the PC itself. It is only as trustworthy as the '
                        'comparison you made against `nestwatch fingerprint`.',
            ),
            const SizedBox(height: 16),
            SelectableText(
              identity.fingerprint.toString(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.controller.unpair();
            },
            child: const Text('Forget this PC'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
