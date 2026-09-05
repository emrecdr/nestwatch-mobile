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

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/nestwatch_api.dart';
import 'frame_label.dart';
import 'poller.dart';
import 'screen_load.dart';

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
  late final Poller _poller = Poller(
    interval: liveFrameCadence,
    tick: () => _load(onTimer: true),
  );

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
  void initState() {
    super.initState();
    _poller.visible = widget.visible;
  }

  @override
  void didUpdateWidget(ScreenshotScreen old) {
    super.didUpdateWidget(old);
    // Leaving the tab stops the stream; returning does not restart it, because `wanted`
    // is the parent's decision and a tab swipe is not. That used to be an if/else that
    // re-derived the conjunction; now it is two independent facts and the Poller decides.
    _poller.visible = widget.visible;
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  void _toggleLive() {
    setState(() => _live = !_live);
    _poller.wanted = _live;
  }

  /// Stop the stream without the parent having asked to.
  ///
  /// Both callers are failures of a kind — a frame at the wrong size, or no frame at
  /// all — and both want the same thing: keep whatever is already on screen, stop
  /// asking for more. Clearing `_live` rather than only cancelling the timer is what
  /// puts the button back to "Start", so the next attempt is a decision somebody made
  /// instead of the app quietly resuming.
  void _stopLive() {
    if (!_live) return;
    setState(() => _live = false);
    _poller.wanted = false;
  }

  /// [onTimer] distinguishes the two callers, and the distinction is auditable.
  ///
  /// nestwatch records a person-requested frame as one `screenshot_taken` row and
  /// coalesces timer frames into a periodic `live_view` row. Getting this backwards is
  /// not cosmetic: a timer that claims to be a person writes ~720 rows an hour into a log
  /// that rotates at 2 MiB, evicting the record of every login and shutdown. A person who
  /// claims to be a timer is the milder error — their deliberate look at a child's screen
  /// goes unrecorded, which is the accountability the audit log exists for.
  Future<void> _load({required bool onTimer}) async {
    // ?tier=preview is inside the client, with no way to ask for anything else.
    final outcome = await loadOnce(
      () => widget.client.screenshotPreview(onTimer: onTimer),
    );
    if (!mounted) return;
    switch (outcome) {
      case Loaded(data: final frame):
        // Drop the decoded copy of the frame this one replaces.
        //
        // Flutter's image cache will not work that out by itself: `MemoryImage` is keyed
        // by the byte buffer, and every frame arrives in a fresh `Uint8List`, so each one
        // is a new entry rather than a replacement of the last. The cache is bounded, but
        // its budget is 100 MiB — half an hour of live view at five seconds fills that
        // with decoded pictures of a child's desktop and goes on holding them after the
        // parent has stopped looking. The bytes displayed right now are kept alive by the
        // live `Image` widget, not by this entry, so evicting is safe.
        final superseded = _frame;
        if (superseded != null) unawaited(MemoryImage(superseded).evict());

        setState(() {
          _frame = frame.bytes;
          _frameAt = DateTime.now();
          _error = frame.isPreview
              ? null
              // Show the picture anyway — it is real and current, and refusing it serves
              // nobody. What is worth stopping is the *stream*: full frames every five
              // seconds is the cost this screen exists to avoid, and one frame is not.
              : 'That PC sent a full-size frame when this app asked for a preview. '
                    'Showing it, but live view has stopped so it does not keep '
                    'arriving at that size.';
        });
        if (!frame.isPreview) _stopLive();
      case Failed(:final message):
        setState(() => _error = message);
        // A failing frame every 5 seconds is noise; let the parent retry deliberately.
        // This matters most for `operationFailed`: on a Windows below the capture floor
        // every frame fails structurally, so retrying is not a transient-error recovery,
        // it is a loop that never terminates and costs the PC work each time.
        _stopLive();
      case HandedBack(:final failure):
        widget.onFailure(failure);
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
                    // The same fact the visible line below states, from the same
                    // function. This used to be `ago()` -- a relative time baked in at
                    // build, on the one screen that stops rebuilding while its content
                    // stays up, so it said "just now" about a frame of any age.
                    semanticLabel: frameLabel(_frameAt),
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
                    onPressed: _live ? null : () => _load(onTimer: false),
                    child: const Text('One frame'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _live
                    ? 'Updating every ${liveFrameCadence.inSeconds} seconds. Live '
                          'viewing is recorded in that PC\'s audit log as a running '
                          'count.'
                    : _frameAt == null
                    ? 'Preview resolution, so text may not be legible. Each single '
                          'frame is recorded on that PC.'
                    : 'Frame from ${frameClock(_frameAt!)}.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              // Below a divider rather than beside the two buttons above, because it is a
              // different kind of act. Those read; this one reaches into the child's
              // session and interrupts them. Putting it in the same row would make a
              // mis-tap between "show me a frame" and "take the screen away from them"
              // one pixel wide.
              const Divider(height: 28),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _locking ? null : _confirmLock,
                  icon: const Icon(Icons.lock_outline, size: 18),
                  label: Text(_locking ? 'Locking…' : 'Lock this screen'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A lock in flight. Debounced for the reason the approve buttons are: the server is
  /// safe under a repeat, and the second tap still costs a round trip and a second audit
  /// row for one decision.
  bool _locking = false;

  /// Ask first, because there is no undo on this side.
  ///
  /// nestwatch publishes no "unlock", and that is right rather than an omission: a
  /// machine is unlocked by the person sitting at it, with their own password. So the
  /// only way back is through the child, which makes this the one control in this app
  /// whose consequence a parent cannot take back by tapping again.
  ///
  /// The copy says what the act actually does, in both directions. "Nothing they had open
  /// is closed" is the fact that separates this from the shutdown endpoint this app
  /// deliberately does not call, and it is the difference between interrupting a child
  /// and destroying their homework.
  Future<void> _confirmLock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lock this screen?'),
        content: const Text(
          'Your child sees the Windows sign-in screen straight away. Nothing they '
          'had open is closed, and their own password brings it all back — so this '
          'interrupts them rather than shutting them out.\n\n'
          'That PC records it in its audit log, the same as it records you watching.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Lock screen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _lock();
  }

  Future<void> _lock() async {
    if (_locking) return;
    setState(() => _locking = true);
    try {
      await widget.client.lockScreen();
      if (!mounted) return;
      _snack('Locked. Your child can sign back in with their own password.');
    } on NestwatchException catch (e) {
      if (!mounted) return;
      // A lapsed session is not a failed lock; it is the whole app needing a password
      // again, and it is handled one level up so every screen answers it the same way.
      if (e.failure == NestwatchFailure.sessionExpired) {
        widget.onFailure(e);
        return;
      }
      // Everything else already carries a sentence written for a parent — the 500 says
      // that nobody is signed in to that PC, a 403 says which kind of refusal it was.
      // Nothing here rewrites them.
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _locking = false);
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
