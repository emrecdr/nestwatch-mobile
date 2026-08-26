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
    if (widget.visible) poller.start();
  }

  @override
  void didUpdateWidget(W oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    widget.visible ? poller.start() : poller.stop();
  }

  @override
  void dispose() {
    poller.dispose();
    super.dispose();
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
