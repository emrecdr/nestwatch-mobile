/// The rule four screens share, tested once.
///
/// Before this file the UI layer had no automated coverage at all — no `testWidgets`
/// anywhere under `test/`, and no mutation in `tool/mutate.sh` reaching `lib/src/ui`.
/// The rule below was written out four times and checked zero times, which is the worst
/// ratio in the repo for a rule that decides whether a parent can get back in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';
import 'package:nestwatch_mobile/src/ui/screen_load.dart';

void main() {
  group('loadOnce sorts a reply three ways', () {
    test('an answer comes back as the answer', () async {
      final outcome = await loadOnce(() async => 41 + 1);
      expect(outcome, isA<Loaded<int>>());
      expect((outcome as Loaded<int>).data, 42);
    });

    test('an ordinary failure becomes something to say', () async {
      final outcome = await loadOnce<int>(
        () async => throw const NestwatchException(
          NestwatchFailure.notOnLan,
          'turn the VPN off',
        ),
      );
      expect(outcome, isA<Failed<int>>());
      expect((outcome as Failed<int>).message, 'turn the VPN off');
    });

    test(
      'a lapsed session is handed up, and is NOT something to say',
      () async {
        // The whole point. A screen that renders this gives a parent a Try again button
        // that cannot work — the session is gone and only a password brings it back —
        // and hides the fact that the controller was never told to ask for one.
        final outcome = await loadOnce<int>(
          () async => throw const NestwatchException(
            NestwatchFailure.sessionExpired,
            'That sign-in expired.',
          ),
        );

        expect(
          outcome,
          isA<HandedBack<int>>(),
          reason: 'sessionExpired must travel past the screen to the controller',
        );
        expect(
          outcome,
          isNot(isA<Failed<int>>()),
          reason: 'and must never become a message the screen shows instead',
        );
        expect(
          (outcome as HandedBack<int>).failure.failure,
          NestwatchFailure.sessionExpired,
        );
      },
    );

    test('a defect in this app is not dressed up as an answer', () async {
      // Only NestwatchException means "that PC said something". A StateError is this
      // app being wrong, and turning it into grey text on a screen is how it would go
      // unnoticed for a release.
      await expectLater(
        loadOnce<int>(() async => throw StateError('bug in the app')),
        throwsStateError,
      );
    });
  });
}
