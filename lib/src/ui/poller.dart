/// A timer that only runs while somebody is looking.
///
/// PLAN.md §5: "Match the dashboard's cadence — 60s for data, 5s for live frames, stop
/// both when not visible". The dashboard's own values are `_pollMs: 60000` and
/// `_refreshMs: 5000` in nestwatch `assets/app.js`; they are mirrored in [dataCadence]
/// and [liveFrameCadence] rather than re-derived.
///
/// "Not visible" means two different things and both have to stop the timer:
///
///   * the app is backgrounded — handled here, via [AppLifecycleListener]. A phone in a
///     pocket polling a screenshot every 5 seconds would drain the battery and, worse,
///     keep writing `live_view` entries into the audit log for a screen nobody is
///     watching;
///   * the tab is off-screen while the app is foregrounded — handled by the owner,
///     which calls [stop] when its tab loses focus. A `TabBarView` keeps its children
///     alive, so a tab that is not shown still has a live State.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Mirrors `_pollMs` in nestwatch `assets/app.js`.
const Duration dataCadence = Duration(seconds: 60);

/// Mirrors `_refreshMs` in nestwatch `assets/app.js`.
const Duration liveFrameCadence = Duration(seconds: 5);

class Poller {
  final Duration interval;
  final Future<void> Function() tick;

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _wanted = false;
  bool _foreground = true;

  /// Guards against overlap: a tick slower than [interval] must not stack up. The
  /// screenshot at 5s over a slow LAN is the realistic case.
  bool _inFlight = false;

  Poller({required this.interval, required this.tick}) {
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _foreground =
            state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive;
        _sync();
      },
    );
  }

  /// Start polling, and fire once immediately — a screen that waits a full minute for
  /// its first paint looks broken.
  void start() {
    _wanted = true;
    _sync();
    unawaited(_fire());
  }

  void stop() {
    _wanted = false;
    _sync();
  }

  void dispose() {
    _wanted = false;
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  void _sync() {
    final shouldRun = _wanted && _foreground;
    if (shouldRun && _timer == null) {
      _timer = Timer.periodic(interval, (_) => unawaited(_fire()));
    } else if (!shouldRun && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  Future<void> _fire() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      await tick();
    } finally {
      _inFlight = false;
    }
  }
}
