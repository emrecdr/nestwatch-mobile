/// Walking skeleton, steps 2-3 (docs/PLAN.md §9).
///
/// Step 2 put a certificate pin over every `dart:io` socket in the process and proved by
/// refusal that a wrong certificate is rejected during the handshake, before any request
/// body exists. Step 3 decides *which* certificate to pin, from a scanned QR — verified
/// when the code carries `#fp=`, trust-on-first-use when it does not.
///
/// The three screens (§5) come after step 4's login.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'src/pairing/pairing_controller.dart';
import 'src/pairing/secure_identity_store.dart';
import 'src/pinning/pinned_http_overrides.dart';
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

  final controller = PairingController(
    overrides: pinnedOverrides,
    identities: const SecureServerIdentityStore(),
    sessions: const SecureSessionStore(),
  );
  // Re-apply a stored pin before the first frame, so the process is never briefly
  // unpinned while a previously-paired server is reachable.
  await controller.restore();

  runApp(NestwatchApp(controller: controller));
}

class NestwatchApp extends StatelessWidget {
  final PairingController controller;
  const NestwatchApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Nestwatch',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E6F5E)),
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E6F5E),
        brightness: Brightness.dark,
      ),
    ),
    home: PairingScreen(controller: controller),
  );
}
