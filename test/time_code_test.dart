import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/models.dart';

void main() {
  group('TimeCode', () {
    test('parses what /api/time-codes returns', () {
      // Captured from a live server: {"code","ts","minutes"}.
      final c = TimeCode.fromJson({
        'code': '128PDKVR',
        'ts': '2026-08-26T14:36:00.892Z',
        'minutes': 30,
      });
      expect(c.code, '128PDKVR');
      expect(c.minutes, 30);
      expect(c.issuedAt, isNotNull);
    });

    test('never renders the code in toString', () {
      // It grants screen time to whoever types it. nestwatch keeps it out of the audit
      // log for exactly this reason; an accidental interpolation in a log line or an
      // error message would be the same leak by a different route.
      const secret = 'ABCD1234';
      final c = TimeCode(code: secret, ts: '', minutes: 30);
      expect(c.toString(), isNot(contains(secret)));
      expect('$c', isNot(contains(secret)));
      expect(c.toString(), contains('redacted'));
    });

    test('a malformed payload does not throw', () {
      final c = TimeCode.fromJson({});
      expect(c.code, isEmpty);
      expect(c.minutes, 0);
      expect(c.issuedAt, isNull);
    });
  });

  group('TimeCodeLimits mirror the server', () {
    test('the range matches MAX_CODE_MINUTES', () {
      // src/timecode.rs: MAX_CODE_MINUTES = 240, and issue_time_code rejects
      // `minutes == 0 || minutes > MAX_CODE_MINUTES` with 400.
      expect(TimeCodeLimits.maxMinutes, 240);
      expect(TimeCodeLimits.isValidMinutes(1), isTrue);
      expect(TimeCodeLimits.isValidMinutes(240), isTrue);
      expect(TimeCodeLimits.isValidMinutes(0), isFalse);
      expect(TimeCodeLimits.isValidMinutes(241), isFalse);
      expect(TimeCodeLimits.isValidMinutes(-5), isFalse);
    });

    test('the active cap matches MAX_ACTIVE_CODES', () {
      expect(TimeCodeLimits.maxActive, 50);
    });
  });
}
