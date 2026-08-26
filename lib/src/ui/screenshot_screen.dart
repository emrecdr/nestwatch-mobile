/// Screen three: what is on that PC's screen right now.
///
/// ## Why the bytes are fetched rather than handed to `Image.network`
///
/// PLAN.md §2 goes to some trouble to establish that `Image.network` *is* pinned by
/// `HttpOverrides.global`, and it is — that argument is what makes any `dart:io` image
/// path safe, including one somebody adds later without reading this. It is still the
/// wrong tool for a live frame, for two reasons that have nothing to do with pinning:
///
///   * Flutter's `ImageCache` keys on the URL, and this URL never changes. A five-second
///     refresh would redisplay the same cached frame indefinitely. The usual fix is a
///     cache-busting query parameter — on a URL where a query parameter is already
///     load-bearing and silently wrong if omitted (trap 4). Two parameters, one of which
///     must be exactly right and one of which must be different every time, is a trap
///     waiting to be sprung.
///   * The session cookie has to ride along, and `dart:io` has no cookie jar (see
///     `NestwatchClient`), so it would have to be threaded in as a raw header.
///
/// Fetching through the client and rendering with `Image.memory` sidesteps both.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/nestwatch_api.dart';
import 'poller.dart';

class ScreenshotScreen extends StatefulWidget {
  final NestwatchClient client;
  final bool visible;
  final void Function(NestwatchException) onFailure;

  const ScreenshotScreen({
    super.key,
    required this.client,
    required this.visible,
    required this.onFailure,
  });

  @override
  State<ScreenshotScreen> createState() => _ScreenshotScreenState();
}

class _ScreenshotScreenState extends State<ScreenshotScreen> {
  late final Poller _poller = Poller(interval: liveFrameCadence, tick: _load);

  Uint8List? _frame;
  DateTime? _frameAt;
  String? _error;

  /// Live view is off by default.
  ///
  /// Not a UI nicety. Every preview frame is coalesced into a `live_view` entry in that
  /// PC's audit log, and a screen that starts streaming the moment it is opened would
  /// record a parent watching their child's desktop whenever they happened to swipe to
  /// this tab. Starting stopped makes watching a thing the parent chose to do.
  bool _live = false;

  @override
  void didUpdateWidget(ScreenshotScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    // Leaving the tab always stops the stream; returning does not restart it, because
    // _live is the parent's decision and a tab swipe is not.
    if (!widget.visible) {
      _poller.stop();
    } else if (_live) {
      _poller.start();
    }
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  void _toggleLive() {
    setState(() => _live = !_live);
    _live ? _poller.start() : _poller.stop();
  }

  Future<void> _load() async {
    try {
      // ?tier=preview is inside the client, with no way to ask for anything else.
      final bytes = await widget.client.screenshotPreview();
      if (!mounted) return;
      setState(() {
        _frame = bytes;
        _frameAt = DateTime.now();
        _error = null;
      });
    } on NestwatchException catch (e) {
      if (!mounted) return;
      if (e.failure == NestwatchFailure.sessionExpired) {
        widget.onFailure(e);
        return;
      }
      setState(() => _error = e.message);
      // A failing frame every 5 seconds is noise; let the parent retry deliberately.
      if (_live) {
        setState(() => _live = false);
        _poller.stop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frame = _frame;
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: Colors.black,
            child: switch ((frame, _error)) {
              (_, final String error?) when frame == null => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
              (final Uint8List bytes, _) => InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    // Without this every new frame fades in from blank, which at 5s
                    // reads as flicker rather than as an update.
                    gaplessPlayback: true,
                  ),
                ),
              ),
              _ => const Center(
                child: Text(
                  'No frame yet.',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (_error != null && frame != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _toggleLive,
                      icon: Icon(_live ? Icons.stop : Icons.play_arrow),
                      label: Text(_live ? 'Stop live view' : 'Watch live'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _live ? null : _load,
                    child: const Text('One frame'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _live
                    ? 'Updating every ${liveFrameCadence.inSeconds} seconds. Live '
                          'viewing is recorded in that PC\'s audit log.'
                    : _frameAt == null
                    ? 'Preview resolution, so text may not be legible.'
                    : 'Frame from ${_clock(_frameAt!)}.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';
}
