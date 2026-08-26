/// The rule PLAN §5 states and nothing was checking.
///
/// "Match the dashboard's cadence — 60s for data, 5s for live frames, stop both when not
/// visible." `poller.dart` spends nine lines arguing why: a phone in a pocket polling a
/// screenshot every five seconds drains the battery, and — worse — writes a `live_view`
/// entry into that PC's audit log for a screen nobody is watching.
///
/// That argument was defended by nothing. The gate lived half in `Poller` and half in a
/// `mixin on State<W>`, which cannot exist without a widget, so no plain test could reach
/// it. Moving visibility into `Poller` is what makes this file possible; the file is the
/// reason the move was worth making.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/ui/poller.dart';

void main() {
  // Poller builds an AppLifecycleListener, which needs bindings.
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<int> ticks;
  late Poller poller;

  setUp(() {
    ticks = [];
    poller = Poller(
      interval: const Duration(seconds: 60),
      tick: () async => ticks.add(1),
    );
  });

  tearDown(() => poller.dispose());

  test('a poller nobody has asked for does not run', () {
    poller.visible = true;
    expect(poller.isRunning, isFalse);
    expect(ticks, isEmpty);
  });

  test('wanting it is not enough while the surface is off screen', () {
    poller.wanted = true;
    poller.visible = false;
    expect(
      poller.isRunning,
      isFalse,
      reason: 'an IndexedStack keeps an off-screen tab alive; it must not keep polling',
    );
    expect(ticks, isEmpty);
  });

  test('both reasons together start it, and it fires at once', () {
    poller
      ..wanted = true
      ..visible = true;
    expect(poller.isRunning, isTrue);
    expect(
      ticks,
      hasLength(1),
      reason: 'a screen that waits a full minute for its first paint looks broken',
    );
  });

  test('losing either reason stops it', () {
    poller
      ..wanted = true
      ..visible = true;
    expect(poller.isRunning, isTrue);

    poller.visible = false;
    expect(poller.isRunning, isFalse, reason: 'tab swiped away');

    poller.visible = true;
    expect(poller.isRunning, isTrue, reason: 'and back');

    poller.wanted = false;
    expect(poller.isRunning, isFalse, reason: 'or the parent pressed stop');
  });

  test('it does not fire again for a reason it already had', () {
    poller
      ..wanted = true
      ..visible = true;
    expect(ticks, hasLength(1));

    // Setting a flag to the value it already holds must not re-enter _sync and fire.
    // didUpdateWidget assigns `visible` on every rebuild, so this is the common path,
    // not an edge case — at the screenshot screen's 5s cadence a redundant fire per
    // rebuild is a request to that PC per rebuild.
    poller.visible = true;
    poller.wanted = true;
    expect(ticks, hasLength(1));
  });

  test('the order the reasons arrive in does not matter', () {
    poller.visible = true;
    expect(poller.isRunning, isFalse);
    poller.wanted = true;
    expect(poller.isRunning, isTrue);
    expect(ticks, hasLength(1));
  });
}
