/// Every JSON shape this app parses, against files nestwatch's own types produced.
///
/// Until these landed, the wire contract had been read as prose — by me, and separately
/// by the session on the other side. Both readings agreed, which is worth something and
/// is also exactly what two people misreading it the same way looks like. These files
/// come out of `serde`, so they cannot be a misreading of anything.
///
/// The cases worth having are the ones prose loses: a null where a zero would be
/// plausible, an empty list where an absent key would be plausible, and a count that is
/// real beside a flag saying nothing was watching.
///
/// Copies rather than reads-in-place — see `test/golden/README.md` for why, and
/// `tool/check_golden.sh` for what keeps the copies honest.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/api/nestwatch_api.dart';

void main() {
  Object? golden(String name) {
    final file = File('test/golden/$name.json');
    // Not a skip. If these go missing the contract is untested, and that has to be
    // loud — a suite that passes because it found nothing to check is the failure
    // mode this file exists to avoid.
    expect(
      file.existsSync(),
      isTrue,
      reason: 'test/golden/$name.json is missing; see test/golden/README.md',
    );
    return jsonDecode(file.readAsStringSync());
  }

  List<Map<String, dynamic>> list(String name) =>
      (golden(name) as List).cast<Map<String, dynamic>>();

  Map<String, dynamic> object(String name) =>
      golden(name) as Map<String, dynamic>;

  group('/session', () {
    test('both answers read as themselves', () {
      expect(
        SessionInfo.fromJson(object('session-signed-in')).authenticated,
        isTrue,
      );
      expect(
        SessionInfo.fromJson(object('session-signed-out')).authenticated,
        isFalse,
      );
    });
  });

  group('/api/time-requests', () {
    test('newest first, and an empty reason survives as empty', () {
      final rows = list('time-requests').map(TimeRequest.fromJson).toList();
      expect(rows, hasLength(2));
      expect(rows.first.minutes, 30);
      expect(rows.first.reason, 'finish the level');
      expect(rows.first.submittedAt, isNotNull);
      // A child who asked for time without saying why. The row is still real, and the
      // screen must render it rather than treat the request as malformed.
      expect(rows[1].reason, isEmpty);
    });

    test('no pending requests is an empty list, not an error', () {
      expect(list('time-requests-empty'), isEmpty);
    });
  });

  group('/api/time-codes', () {
    test('a code is six characters, which is what the server now mints', () {
      final codes = list('time-codes').map(TimeCode.fromJson).toList();
      expect(codes, hasLength(1));
      expect(
        codes.single.code.length,
        object('limits')['code_len'],
        reason:
            'the sample is minted from CODE_LEN, and limits.json publishes it — '
            'two files from the same constants, checked against each other',
      );
      expect(codes.single.minutes, 45);
      expect(codes.single.issuedAt, isNotNull);
    });

    test('and toString still refuses to render one', () {
      final code = list('time-codes').map(TimeCode.fromJson).single;
      expect(code.toString(), isNot(contains(code.code)));
    });

    test('none outstanding is an empty list', () {
      expect(list('time-codes-empty'), isEmpty);
    });
  });

  group('limits — the numbers shown before a request can answer', () {
    // These run on every commit now. They used to be `tool/check_golden.sh` grepping
    // nestwatch's Rust for the constants, which is an out-of-band script somebody has to
    // remember to point at a sibling checkout — and whose failure mode is that the check
    // stops running rather than that a number is wrong. It did stop, hours after it was
    // written, when those constants were given names.
    //
    // A phone renders "1 to 240 minutes" and "5 tries, then a minute" from its own
    // compiled-in copies, before any call it could be corrected by. That is what makes
    // them contract rather than configuration.
    test('agree with what that PC enforces', () {
      final limits = object('limits');
      expect(TimeCodeLimits.maxMinutes, limits['max_code_minutes']);
      expect(TimeCodeLimits.maxActive, limits['max_active_codes']);
      expect(LoginLimits.maxAttempts, limits['login_max_fails']);
      expect(LoginLimits.lockoutSeconds, limits['login_lockout_secs']);
    });

    test('and the sentences built from them say the real numbers', () {
      final limits = object('limits');
      // The lockout used to exist here only as the word "minute" inside a sentence.
      expect(
        LoginLimits.lockoutInWords(),
        'a minute',
        reason: 'renders ${limits['login_lockout_secs']} seconds',
      );
      expect(
        LoginLimits.lockout.inSeconds,
        limits['login_lockout_secs'],
        reason: 'the Duration and the number it is built from cannot disagree',
      );
    });
  });

  group('/api/usage/today', () {
    test('an ordinary day reads as an ordinary day', () {
      final usage = UsageToday.fromJson(object('usage-today'));
      expect(usage.day, '2026-08-26');
      expect(usage.usedMinutes, 55);
      expect(usage.remainingMinutes, 80);
      expect(usage.isUnlimited, isFalse);
      expect(usage.enforcementMayBeStopped, isFalse);
      expect(usage.focused.map((r) => r.name), ['minecraft', 'chrome']);
      expect(usage.perApp.single.limitMinutes, 60);
      expect(usage.pages.single.name, 'Poki - Free Online Games');
      expect(usage.groups, isEmpty);

      // Arrived in the payload on 2026-09-01. Pinned here even though no screen reads
      // them yet (M20): the point of this file is that the wire shape is recorded from
      // files serde produced, and a field nothing asserts is a field that can change
      // without anyone finding out.
      expect(usage.certDaysLeft, 700);
      expect(usage.certExpiring, isFalse);

      // Arrived with nestwatch 0.6.0. `refused_total` is taken as sent rather than summed
      // here, so this asserts the *server's* arithmetic reached the model -- a client that
      // re-added the three parts would also produce 6 and would pass a weaker check.
      expect(usage.refused.clockChanges, 2);
      expect(usage.refused.dayResets, 1);
      expect(usage.refused.shutdownCancels, 3);
      expect(usage.refused.total, 6);
      expect(usage.refused.any, isTrue);

      // null here, and it is the ordinary case: the base rules are in force, so there is
      // no routine to name. A blank name would be worse than none -- see `_nonEmpty`.
      expect(usage.activeRoutine, isNull);
    });

    test('the four nulls that prose keeps losing', () {
      final usage = UsageToday.fromJson(object('usage-today-unmeasured'));

      expect(usage.day, isNull, reason: 'null, not absent-and-defaulted');

      // The one that matters most. remaining_mins: null means "no limit", and reading it
      // as zero would tell a parent their child is out of time when they have all of it.
      expect(usage.remainingMinutes, isNull);
      expect(usage.isUnlimited, isTrue);

      // enforcer_age_secs: null means the PC did not say. Never healthy — a heartbeat
      // that is absent has to read the same as one that stopped.
      expect(usage.enforcerAgeSeconds, isNull);
      expect(usage.enforcementMayBeStopped, isTrue);

      // cert_days_left: null means that PC could not say — same shape as the nulls above.
      // cert_expiring is false there rather than null, because the server sends a verdict
      // and "I could not tell" is spelled by the day count, not by the flag.
      expect(usage.certDaysLeft, isNull);
      expect(usage.certExpiring, isFalse);

      // 10 minutes of use, and nothing recorded what was in front. "Nothing was
      // watching", not "nothing happened" — the empty lists below are the absence of a
      // watcher, not the absence of a child.
      expect(usage.usedMinutes, 10);
      expect(usage.focusMissing, isTrue);
      expect(usage.focused, isEmpty);
      expect(usage.perApp, isEmpty);

      // The zeros are *sent*, not absent -- nestwatch always reports `refused`, so that a
      // test can see the field is being produced at all. Reading them as a quiet day is
      // this side's job, and `any` is where that happens.
      expect(usage.refused.total, 0);
      expect(usage.refused.any, isFalse);
      expect(usage.activeRoutine, isNull);
    });
  });
}
