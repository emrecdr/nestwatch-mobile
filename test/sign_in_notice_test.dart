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
  bool held = false;

  _Recording(this.log);

  @override
  Future<bool> announced() async => held;

  @override
  Future<void> markAnnounced() async {
    log.add('record');
    held = true;
  }

  @override
  Future<void> clear() async {
    log.add('clear');
    held = false;
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

  test('a second raise says nothing more', () async {
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
