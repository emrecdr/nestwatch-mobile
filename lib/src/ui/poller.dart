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

  /// Three independent reasons to be running, all of which must hold.
  ///
  /// The gate was already two-input — wanted and foreground — reconciled in one place by
  /// [_sync]. Visibility was the third, and it lived outside: `PolledScreenState` mapped
  /// it onto [start]/[stop], which collapses a predicate into a command and left the
  /// screenshot screen, which has two reasons of its own, re-deriving the conjunction by
  /// hand in three places.
  ///
  /// Keeping all three here also puts the rule somewhere a plain test can reach it.
  /// PLAN §5 — "stop both when not visible" — was defended by nothing while it lived in
  /// a mixin that cannot exist without a widget.
  bool _wanted = false;

  /// Starts **false**, so a poller runs only once it has been told all three reasons
  /// hold. Defaulting it to true opened a window: `wanted = true` before
  /// `visible = false` starts the timer and fires once, which for a tab that opens
  /// off-screen is a real request to that PC — three of them at app start, four tabs
  /// deep. The first test written against this gate found exactly that, in the change
  /// that made the gate testable.
  bool _visible = false;
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

  /// Whether anybody has asked for this — a tab that is on screen, a parent who pressed
  /// Start. Not the same question as whether it is *reachable*.
  set wanted(bool value) {
    if (_wanted == value) return;
    _wanted = value;
    _sync();
  }

  /// Whether the surface this polls for is the one being looked at. An [IndexedStack]
  /// keeps every child alive, so a screen that is off-screen still has a live State and
  /// would otherwise go on asking that PC for things nobody is reading.
  set visible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _sync();
  }

  bool get isRunning => _timer != null;

  void dispose() {
    _wanted = false;
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  void _sync() {
    final shouldRun = _wanted && _visible && _foreground;
    if (shouldRun && _timer == null) {
      _timer = Timer.periodic(interval, (_) => unawaited(_fire()));
      // Fire on the transition into running, not on whoever set the last flag. A screen
      // that waits a full minute for its first paint looks broken, and which of the three
      // reasons arrived last is not something a caller should have to think about.
      unawaited(_fire());
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
