/// Telling the parent once, and un-telling them when it stops being true.
///
/// The ordering rules live in `SignInNotice` rather than in `pollOnce` because they are
/// only correct together: a flag written without the notification posted is a parent
/// never told, and a notification posted without the flag written is the fifteen-minute
/// alarm the store exists to prevent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/background/sign_in_notice.dart';

/// Records what happened in order, so "announced before recorded" is checkable.
class _Recording implements SignInNoticeStore {
  final List<String> log;
  DateTime? at;

  _Recording(this.log);

  /// Whether a notice is standing. A getter rather than a field so there is one place
  /// that decides what "held" means now that the store keeps a time rather than a bit.
  bool get held => at != null;

  @override
  Future<DateTime?> announcedAt() async => at;

  @override
  Future<void> markAnnounced(DateTime when) async {
    log.add('record');
    at = when;
  }

  @override
  Future<void> clear() async {
    log.add('clear');
    at = null;
  }
}

void main() {
  test('the parent is told before it is written down', () async {
    final log = <String>[];
    final store = _Recording(log);
    await SignInNotice(
      store: store,
      announce: () async => log.add('announce'),
      withdraw: () async {},
    ).raise();

    expect(log, ['announce', 'record']);
  });

  test('a notification that fails to post is not recorded as sent', () async {
    // The reason for that order. Recording first would mark the parent as told, and the
    // flag would then suppress every later attempt — permanently, silently, because the
    // background isolate reports success either way.
    final log = <String>[];
    final store = _Recording(log);
    final notice = SignInNotice(
      store: store,
      announce: () async => throw StateError('no notification channel'),
      withdraw: () async {},
    );

    await expectLater(notice.raise(), throwsA(isA<StateError>()));
    expect(store.held, isFalse, reason: 'the next round has to try again');
    expect(log, isEmpty);
  });

  test('a second raise in the same round says nothing more', () async {
    final log = <String>[];
    final store = _Recording(log);
    final notice = SignInNotice(
      store: store,
      announce: () async => log.add('announce'),
      withdraw: () async {},
    );

    await notice.raise();
    await notice.raise();
    await notice.raise();

    expect(log.where((e) => e == 'announce'), hasLength(1));
  });

  group('a notice the parent did not act on comes back, but not soon', () {
    test('the interval is a day', () {
      // Every clock advance below is a **literal** duration, and this is why. They used to
      // read `t.pass(SignInNotice.renotifyAfter)`, which moved the clock by whatever the
      // constant said -- so widening it to a century moved the clock a century too and the
      // assertions went on passing. The mutation audit found that: "the notice is never
      // repeated" SURVIVED against a suite that looked like it covered exactly that.
      //
      // A test whose input is derived from the thing under test cannot see the thing
      // change. `docs/OPEN-FINDINGS.md` M26 records the same shape one file over, in a gate
      // keyed on a version instead of on the fact the server states.
      //
      // So the durations below are fixed, and the constant is pinned here. Changing it is
      // then a deliberate edit to this line rather than a silent no-op across five tests.
      expect(SignInNotice.renotifyAfter, const Duration(days: 1));
    });

    /// A clock the test moves, because the rule under test is about elapsed time and a
    /// test that cannot move it can only ever check the branch it is standing in.
    ({
      SignInNotice notice,
      _Recording store,
      List<String> log,
      void Function(Duration) pass,
    })
    build() {
      final log = <String>[];
      final store = _Recording(log);
      var clock = DateTime.utc(2026, 9, 5, 9);
      return (
        notice: SignInNotice(
          store: store,
          announce: () async => log.add('announce'),
          withdraw: () async => log.add('withdraw'),
          now: () => clock,
        ),
        store: store,
        log: log,
        pass: (d) => clock = clock.add(d),
      );
    }

    test('an hour later it stays quiet', () async {
      final t = build();
      await t.notice.raise();
      t.pass(const Duration(hours: 1));
      await t.notice.raise();

      expect(t.log.where((e) => e == 'announce'), hasLength(1));
    });

    test('just under a day later it still stays quiet', () async {
      final t = build();
      await t.notice.raise();
      t.pass(const Duration(hours: 23, minutes: 59));
      await t.notice.raise();

      expect(t.log.where((e) => e == 'announce'), hasLength(1));
    });

    test('a day later it says it again', () async {
      // The defect this replaced: the record was a bare bit, so "already told" was
      // permanent until a poll SUCCEEDED — and a poll cannot succeed while the session is
      // the broken thing. A parent who swiped the notice away was never told again, for
      // as long as the lapse lasted, which is until they happened to open the app.
      final t = build();
      await t.notice.raise();
      t.pass(const Duration(days: 1));
      await t.notice.raise();

      expect(t.log.where((e) => e == 'announce'), hasLength(2));
    });

    test(
      'and the repeat resets the clock rather than repeating daily forever',
      () async {
        final t = build();
        await t.notice.raise();
        t.pass(const Duration(days: 1));
        await t.notice.raise();
        t.pass(const Duration(hours: 1));
        await t.notice.raise();

        expect(
          t.log.where((e) => e == 'announce'),
          hasLength(2),
          reason: 'the second notice is as recent as the first one was',
        );
      },
    );

    test(
      'a clock that moved BACKWARDS says it again rather than going quiet',
      () async {
        // `elapsed < renotifyAfter` is true of every negative duration, so the naive
        // comparison suppresses the notice for as long as the clock stays behind. A phone
        // that lost its battery, or crossed a timezone database update, would go silent
        // about the one thing it cannot afford to be silent about. One repeat is the cheap
        // error; indefinite silence is the expensive one.
        final t = build();
        await t.notice.raise();
        t.pass(const Duration(days: -30));
        await t.notice.raise();

        expect(t.log.where((e) => e == 'announce'), hasLength(2));
      },
    );
  });

  test('it is taken down before it is re-armed', () async {
    final log = <String>[];
    final store = _Recording(log);
    final notice = SignInNotice(
      store: store,
      announce: () async {},
      withdraw: () async => log.add('withdraw'),
    );

    await notice.raise();
    log.clear();
    await notice.lower();

    expect(log, ['withdraw', 'clear']);
  });

  test('a withdrawal that fails leaves the flag set, so it is retried', () async {
    final log = <String>[];
    final store = _Recording(log);
    var fail = true;
    final notice = SignInNotice(
      store: store,
      announce: () async {},
      withdraw: () async {
        if (fail) throw StateError('channel down');
        log.add('withdraw');
      },
    );

    await notice.raise();
    await expectLater(notice.lower(), throwsA(isA<StateError>()));
    expect(
      store.held,
      isTrue,
      reason:
          'clearing first would strand a notice with nothing left to remove it',
    );

    fail = false;
    await notice.lower();
    expect(store.held, isFalse);
  });

  test('lowering what was never raised does nothing at all', () async {
    // Runs on every successful poll — four times an hour, forever — so it must not
    // cancel a notification that was never posted.
    final log = <String>[];
    await SignInNotice(
      store: _Recording(log),
      announce: () async {},
      withdraw: () async => log.add('withdraw'),
    ).lower();

    expect(log, isEmpty);
  });

  test('the lapse after a recovery is announced again', () async {
    // What `clear` is for. A phone re-paired in September must still be able to tell its
    // parent about the lapse in October.
    final log = <String>[];
    final notice = SignInNotice.recording(log);

    await notice.raise();
    await notice.lower();
    await notice.raise();

    expect(log, [
      SignInNotice.raised,
      SignInNotice.lowered,
      SignInNotice.raised,
    ]);
  });
}
