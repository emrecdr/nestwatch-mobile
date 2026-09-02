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
import '../api/server_contract.dart';
import '../api/server_events.dart';
import '../pinning/certificate_expiry.dart';
import '../pairing/pairing_controller.dart';
import '../pairing/server_identity.dart';
import 'notice.dart';
import 'poller.dart';
import 'privacy_screen.dart';
import 'notifications_sheet.dart';
import 'screenshot_screen.dart';
import 'time_codes_screen.dart';
import 'time_requests_screen.dart';
import 'usage_screen.dart';

class HomeScreen extends StatefulWidget {
  final PairingController controller;
  final NestwatchClient client;
  final ServerIdentity identity;

  /// What `GET /session` answered, kept for its `version`.
  ///
  /// The pairing screen shows the version verdict before a password is typed; this side
  /// keeps showing it, for the same reason `PinProvenance` is not a one-time banner. A
  /// caveat that appears once and is then forgotten leaves every later screen looking
  /// exactly as authoritative as one with nothing wrong.
  final SessionInfo session;

  const HomeScreen({
    super.key,
    required this.controller,
    required this.client,
    required this.identity,
    required this.session,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  /// One revision counter per subject that PC can invalidate.
  ///
  /// A counter rather than a callback list because the screens are rebuilt with new
  /// widget instances on every tab change: a [Listenable] they can re-bind to survives
  /// that, where a closure captured at construction would go stale.
  final Map<String, ValueNotifier<int>> _stale = {
    for (final subject in knownEventTags) subject: ValueNotifier<int>(0),
  };

  /// The single event connection. One for the whole screen, not one per tab — four
  /// subscriptions to the same stream would be four held connections to that PC.
  late final ServerEvents _events = ServerEvents(
    open: () => widget.client.events(),
    onChanged: (subject) => _stale[subject]?.value++,
    // A 401 here means what it means anywhere else, and reconnecting cannot fix it.
    // This fires for the lapsed session and nothing else — see [ServerEvents.onSessionLost]
    // for the older PC that used to take this same exit and end up signed out in a loop.
    onSessionLost: (_) => widget.controller.signOut(),
  );

  /// Stops the stream while the app is backgrounded.
  ///
  /// [Poller] already does this for polling, but it holds no connection between ticks —
  /// this does. A pocketed phone keeping a TCP connection open to that PC costs battery
  /// for events nobody can see, and the OS is liable to tear it down anyway, which would
  /// just feed the backoff loop.
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _events.start();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) =>
          isForeground(state) ? _events.start() : _events.stop(),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _events.stop();
    for (final notifier in _stale.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  /// The caveats worth a strip across every screen, in the order a parent should read
  /// them. Empty on the ordinary day, which is why the strip is a loop over nothing
  /// rather than a widget that renders blank.
  List<({String message, IconData icon, NoticeTone tone})> _caveats(
    ContractCheck contract,
    CertificateExpiry? expiry,
  ) => [
    if (contract.isWarning)
      (
        message: contract.message!,
        icon: Icons.warning_amber,
        tone: NoticeTone.warning,
      ),
    if (expiry != null && expiry.isWarning)
      (
        message: expiry.message!,
        icon: Icons.event_busy,
        // A certificate that has lapsed is a broken dashboard now; one lapsing next week
        // is a thing to schedule. Same strip, different weight — a week of red for
        // something that still works everywhere would train the parent past it, which is
        // how the enforcer warning below earns its own colour by being rarer.
        tone: expiry.life == CertificateLife.expired
            ? NoticeTone.warning
            : NoticeTone.advisory,
      ),
  ];

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
    final contract = ContractCheck.of(widget.session.version);
    final expiry = CertificateExpiry.of(widget.controller.pinnedNotAfter);
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
      body: Column(
        children: [
          // Both verdicts render identically; only the icon differs. Written out twice
          // they were two places to change a margin, and a third caveat would have been
          // a third copy. The types stay separate — a version disagreement and a lapsed
          // certificate are different subjects with different sentences — but "a caveat
          // bad enough for a permanent strip" is one rendering.
          //
          // Each is here only for the case that actually breaks something: a PC older
          // than this app, and a certificate already past its date. Being newer, being
          // unreadable, or being a month from expiry all still work everywhere, and
          // belong in the identity dialog rather than banded across every screen.
          for (final caveat in _caveats(contract, expiry))
            Notice(
              caveat.message,
              tone: caveat.tone,
              icon: caveat.icon,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                TimeRequestsScreen(
                  client: widget.client,
                  visible: _tab == 0,
                  onFailure: _onFailure,
                  invalidatedBy: _stale[requestsSubject],
                ),
                UsageScreen(
                  client: widget.client,
                  visible: _tab == 1,
                  onFailure: _onFailure,
                  invalidatedBy: _stale[usageSubject],
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
    final contract = ContractCheck.of(widget.session.version);
    final expiry = CertificateExpiry.of(widget.controller.pinnedNotAfter);
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
            const Divider(height: 28),
            // Stated in every outcome, including agreement — a version line that appears
            // only when something is wrong cannot be distinguished, on the screen where
            // nothing is wrong, from a check that was never made.
            Text(
              contract.message ??
                  'That PC is running nestwatch ${contract.reported}, which is what '
                      'this app was built and tested against.',
            ),
            if (expiry?.message case final warning?) ...[
              const SizedBox(height: 12),
              Text(warning),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(PrivacyScreen.route());
            },
            child: const Text('Privacy'),
          ),
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
