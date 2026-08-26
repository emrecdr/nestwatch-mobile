import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/models.dart';

void main() {
  _loginLimits();
  group('UsageToday', () {
    // Captured off the wire from nestwatch 0.3.0, not hand-written from the Rust types.
    const wire = '''
    {
      "budget_mins": 0,
      "day": "2026-08-26",
      "enabled": true,
      "enforcer_age_secs": 27,
      "extra_mins": 0,
      "focus_missing": false,
      "focused": [],
      "groups": [],
      "pages": [],
      "per_app": [],
      "remaining_mins": null,
      "used_mins": 0
    }''';

    UsageToday parse(String json) =>
        UsageToday.fromJson(jsonDecode(json) as Map<String, dynamic>);

    test('parses the real payload', () {
      final u = parse(wire);
      expect(u.day, '2026-08-26');
      expect(u.enabled, isTrue);
      expect(u.usedMinutes, 0);
      expect(u.enforcerAgeSeconds, 27);
    });

    test('remaining_mins is null under an unlimited budget, NOT zero', () {
      // The distinction a naive `as int` would crash on, and a `?? 0` would misreport
      // as "no time left" when the truth is "no limit set".
      final u = parse(wire);
      expect(u.remainingMinutes, isNull);
      expect(u.isUnlimited, isTrue);
    });

    test('a real budget reads as limited', () {
      final u = parse(
        '{"budget_mins":120,"used_mins":30,"remaining_mins":90,'
        '"enforcer_age_secs":5}',
      );
      expect(u.isUnlimited, isFalse);
      expect(u.remainingMinutes, 90);
    });

    group('separating a quiet day from a dead enforcer', () {
      // nestwatch: enforcer_age_secs is "the only signal that distinguishes a dead
      // enforcer from a quiet day, since both otherwise show zero minutes used".
      test('a fresh heartbeat is not treated as stopped', () {
        expect(
          parse(
            '{"used_mins":0,"enforcer_age_secs":27}',
          ).enforcementMayBeStopped,
          isFalse,
        );
      });

      test('a stale heartbeat is', () {
        expect(
          parse(
            '{"used_mins":0,"enforcer_age_secs":36000}',
          ).enforcementMayBeStopped,
          isTrue,
        );
      });

      test('and a MISSING heartbeat is, rather than being assumed healthy', () {
        // Absent must fail toward the warning: silently reading as "fine" is exactly
        // how a dead enforcer gets reported as a quiet day.
        expect(parse('{"used_mins":0}').enforcementMayBeStopped, isTrue);
      });
    });

    test('focus_missing is carried through', () {
      expect(parse('{"focus_missing":true}').focusMissing, isTrue);
      expect(parse('{}').focusMissing, isFalse);
    });

    test('an empty payload does not throw', () {
      // Every field is defaulted, because a screen that crashes tells a parent less
      // than a screen showing zeroes with its caveats attached.
      final u = parse('{}');
      expect(u.usedMinutes, 0);
      expect(u.perApp, isEmpty);
    });
  });

  group('UsageRow reads both key spellings', () {
    // per_app/groups send {name, used_mins, limit_mins}; focused/pages send
    // {name, minutes}. They render identically, so one reader handles both.
    test('used_mins with a limit', () {
      final r = UsageRow.fromJson({
        'name': 'roblox.exe',
        'used_mins': 42,
        'limit_mins': 60,
      });
      expect(r.name, 'roblox.exe');
      expect(r.minutes, 42);
      expect(r.limitMinutes, 60);
    });

    test('minutes with no limit', () {
      final r = UsageRow.fromJson({'name': 'Roblox', 'minutes': 15});
      expect(r.minutes, 15);
      expect(r.limitMinutes, isNull);
    });
  });

  group('TimeRequest', () {
    test('parses what the queue returns', () {
      final r = TimeRequest.fromJson({
        'id': '1a03d7d72ca-1',
        'ts': '2026-08-26T09:53:46.698Z',
        'minutes': 30,
        'reason': 'homework video',
      });
      expect(r.id, '1a03d7d72ca-1');
      expect(r.minutes, 30);
      expect(r.reason, 'homework video');
      expect(r.submittedAt, isNotNull);
    });

    test('an empty reason is allowed — the field is #[serde(default)]', () {
      final r = TimeRequest.fromJson({'id': 'x', 'ts': '', 'minutes': 5});
      expect(r.reason, isEmpty);
      expect(r.submittedAt, isNull);
    });
  });
}

/// The limiter a phone runs into after five wrong passwords.
///
/// These numbers used to exist here only as the word "minute" inside a sentence, which
/// is a copy of a rule that PC enforces with nothing to grep and nothing to pin.
/// `tool/check_golden.sh` compares the constants against `LoginLimiter::default`; these
/// pin the sentence to the constants, so the two cannot drift apart on this side either.
void _loginLimits() {
  group('LoginLimits', () {
    test('matches what nestwatch enforces today', () {
      // Literals on purpose. Asserting a constant against itself pins nothing — the job
      // here is to make a change to either number deliberate, and to fail next to a
      // comment saying where the other copy lives.
      expect(LoginLimits.maxAttempts, 5);
      expect(LoginLimits.lockout, const Duration(seconds: 60));
    });

    test('a parent is told the real wait, in words they would use', () {
      expect(LoginLimits.lockoutInWords(), 'a minute');
      expect(
        LoginLimits.lockoutInWords(const Duration(seconds: 60)),
        'a minute',
      );
      expect(
        LoginLimits.lockoutInWords(const Duration(minutes: 5)),
        '5 minutes',
      );
      expect(
        LoginLimits.lockoutInWords(const Duration(seconds: 90)),
        '90 seconds',
      );
    });
  });
}
