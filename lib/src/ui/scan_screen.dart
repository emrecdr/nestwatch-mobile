/// The in-app QR scanner.
///
/// PLAN.md trap 3: the pairing token is single-use, and the instruction printed under
/// the QR ("Scan this with your phone's camera — it opens the dashboard, signed in")
/// spends it in a *browser*. A parent cannot scan the same QR with both, and the QR can
/// never deep-link here either — `https://192.168.1.42:8443/…` is an IP address, and
/// App Links need a verifiable domain. So the app has to own the camera, and the copy on
/// this screen has to tell the parent not to use the system camera app.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(
    // Only QR. Narrowing the formats keeps the detector off barcodes it will never be
    // pointed at, and avoids a stray EAN-13 on some packaging reading as a scan.
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// The detector fires repeatedly while the code stays in frame; the first hit wins.
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final value = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (value == null) return;
    _handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan the pairing code')),
    body: Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(controller: _controller, onDetect: _onDetect),
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 3),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Scan the QR code that `nestwatch install` printed, using this screen — '
            'not your phone\'s camera app. The code works only once, and opening it in '
            'a browser uses it up.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    ),
  );
}
