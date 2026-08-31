/// Walking skeleton, complete (docs/PLAN.md §9).
///
///   2. a pinned `HttpClient` over every `dart:io` socket, proven by refusal
///   3. QR scan, `#fp=` parsing, and the trust-on-first-use fallback
///   4. token redemption, password login, and a session that survives a restart
///   5. three screens: time requests, today's usage, the screenshot
///
/// Rules, routines, curfew and the audit log stay in the browser, deliberately (§5).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'src/background/background_poll.dart';
import 'src/background/notifications.dart';
import 'src/pairing/pairing_controller.dart';
import 'src/pairing/secure_identity_store.dart';
import 'src/pinning/pinned_http_overrides.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/pairing_screen.dart';

/// The process-wide pin.
///
/// Held at top level rather than inside a widget because [HttpOverrides.global] is set
/// exactly once, before any client exists, and the pin has to outlive every rebuild.
final pinnedOverrides = PinnedHttpOverrides();

Future<void> main() async {
  // Before runApp, and before anything can touch `Image.network`'s lazily-initialised
  // static client — which is the whole reason a global override reaches it at all.
  HttpOverrides.global = pinnedOverrides;

  WidgetsFlutterBinding.ensureInitialized();

  // Hands WorkManager the background entry point. This only *registers* the dispatcher;
  // nothing is scheduled until the parent turns notifications on.
  //
  // The task runs in its own isolate, which never executes this function — see
  // `background_session.dart` for why that matters more than it looks.
  await Workmanager().initialize(callbackDispatcher);
  await initNotifications();

  final controller = PairingController(
    overrides: pinnedOverrides,
    identities: const SecureServerIdentityStore(),
    sessions: const SecureSessionStore(),
    seen: const SecureSeenRequestStore(),
  );
  // Re-apply the stored pin before the first frame, so the process is never briefly
  // unpinned while a previously-paired server is reachable. Keystore reads only.
  await controller.restorePin();

  runApp(NestwatchApp(controller: controller));

  // Whether that stored session is still good is a question for the PC, and asking it
  // takes a handshake and a GET. Off the home network that runs to the timeout, so it
  // happens behind a frame the parent can already see rather than in front of a blank
  // one. `_Root` listens to the controller and rebuilds when the answer arrives.
  unawaited(controller.restoreSession());
}

class NestwatchApp extends StatelessWidget {
  final PairingController controller;
  const NestwatchApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E6F5E);
    return MaterialApp(
      title: 'Nestwatch',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
      ),
      home: _Root(controller: controller),
    );
  }
}

/// Swaps the pairing flow for the three screens once there is a signed-in session.
///
/// Done here rather than inside [PairingScreen] so the two never nest: the three screens
/// own a `Scaffold` with its own navigation bar, and pairing is a different shape of
/// thing entirely — a linear flow with one way forward.
class _Root extends StatefulWidget {
  final PairingController controller;
  const _Root({required this.controller});

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
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

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final client = widget.controller.client;

    if (state is PairingConnected && client != null) {
      return HomeScreen(
        // Keyed on the server so switching PCs rebuilds the screens rather than showing
        // one PC's frames under another's name.
        key: ValueKey(state.identity.authority),
        controller: widget.controller,
        client: client,
        identity: state.identity,
        session: state.session,
      );
    }
    return PairingScreen(controller: widget.controller);
  }
}
