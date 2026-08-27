/// The part of a tab that is the same in every tab.
///
/// Three of the four screens are one shape with different nouns: ask an endpoint for a
/// thing, ask again every minute while somebody is looking, stop when they are not, and
/// show either the thing, a message, or a spinner. Written out per screen that came to
/// roughly forty-five identical lines each — including [Poller] wiring, the visibility
/// gate, and the `sessionExpired` rule that decides whether a parent can get back in.
///
/// The screenshot screen deliberately does not use this. It polls on a different
/// cadence, starts stopped because streaming is a thing a parent chooses, and does not
/// resume when its tab comes back. Bending this to fit it would put four special cases
/// into shared code to save one file forty lines — so it keeps its own wiring and shares
/// only [loadOnce], which is the part that actually has to agree.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/nestwatch_api.dart';
import 'poller.dart';
import 'screen_load.dart';

/// A tab that polls while it is on screen.
abstract class PolledScreen extends StatefulWidget {
  const PolledScreen({super.key});

  /// Whether this tab is the one being looked at.
  ///
  /// An [IndexedStack] keeps every child alive so each keeps its state across a switch,
  /// which means a screen that is not on screen still has a live `State` and would go on
  /// asking that PC for things nobody is reading.
  bool get visible;

  /// Where a lapsed session goes. See [loadOnce] for why it must not stop here.
  void Function(NestwatchException) get onFailure;

  /// Fires when that PC says this screen's data has changed (`GET /api/events`).
  ///
  /// Null for a screen with no tag of its own, which then just polls. This is an
  /// *early* refetch and never the only one — the cadence below is what guarantees a
  /// screen is not stale, because a stream that died quietly looks exactly like a house
  /// where nothing is happening.
  Listenable? get invalidatedBy => null;
}

mixin PolledScreenState<W extends PolledScreen, T> on State<W> {
  /// The one call this screen makes.
  Future<T> fetch();

  /// How often to repeat it. Mirrors the dashboard unless a screen says otherwise.
  Duration get cadence => dataCadence;

  /// Somewhere to reconcile other state against freshly arrived data, inside the same
  /// `setState` that adopts it. Time codes use it to forget reveals for codes that have
  /// since been redeemed.
  void onLoaded(T data) {}

  late final Poller poller = Poller(interval: cadence, tick: load);

  /// The last good answer, or null before the first one arrives.
  T? data;

  /// Something worth saying, or null when there is nothing wrong. Never holds a lapsed
  /// session — that is handed up instead.
  String? error;

  @override
  void initState() {
    super.initState();
    // A data tab always wants to be polling; whether it gets to is visibility's business
    // and the Poller's to reconcile.
    poller
      ..wanted = true
      ..visible = widget.visible;
    widget.invalidatedBy?.addListener(_invalidated);
  }

  @override
  void didUpdateWidget(W oldWidget) {
    super.didUpdateWidget(oldWidget);
    poller.visible = widget.visible;
    if (!identical(oldWidget.invalidatedBy, widget.invalidatedBy)) {
      oldWidget.invalidatedBy?.removeListener(_invalidated);
      widget.invalidatedBy?.addListener(_invalidated);
    }
  }

  @override
  void dispose() {
    widget.invalidatedBy?.removeListener(_invalidated);
    poller.dispose();
    super.dispose();
  }

  /// That PC says this screen is stale.
  ///
  /// Gated on visibility for the same reason the poller is: an off-screen tab that
  /// refetches is a real request to that PC for something nobody is reading, and with
  /// four tabs alive at once one event would become four. A tab coming back on screen
  /// already fires immediately — [Poller] does that on the transition into running — so
  /// nothing is lost by waiting.
  void _invalidated() {
    if (!widget.visible || !mounted) return;
    unawaited(load());
  }

  Future<void> load() async {
    final outcome = await loadOnce(fetch);
    if (!mounted) return;
    switch (outcome) {
      case Loaded(data: final fresh):
        setState(() {
          data = fresh;
          error = null;
          onLoaded(fresh);
        });
      case Failed(:final message):
        setState(() => error = message);
      case HandedBack(:final failure):
        widget.onFailure(failure);
    }
  }

  /// What to show before there is anything to show.
  ///
  /// A spinner, or the reason there is nothing and a way to ask again. Screens call this
  /// when [data] is still null; once there is data they keep showing it, because a stale
  /// number with a message beside it beats a blank screen.
  Widget waitingPane() {
    final message = error;
    if (message == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: load, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
