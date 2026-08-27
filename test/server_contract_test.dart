/// PLAN §5 step 2: `/session` "gives `version` for compatibility checks before anything
/// secret is sent". The probe existed for months; the comparison did not, and `version`
/// was parsed and dropped. These are the branches that check it is a real comparison and
/// not a field being read.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/server_contract.dart';

/// Versions expressed *relative to* [ContractCheck.testedAgainst], never spelled out.
///
/// The first cut of this file hardcoded '0.4.0' as the newer one. nestwatch shipped 0.4.0
/// the same day, `testedAgainst` moved to match, and the test that claimed to describe a
/// newer PC was suddenly describing an identical one — it failed loudly, which is the good
/// case, but only because the branch it asserted happened to change. A fixture that names
/// a constant it is defined against is a fixture with an expiry date on it.
String _relative(int minorOffset) {
  final parts = ContractCheck.testedAgainst.split('.');
  return '${parts[0]}.${int.parse(parts[1]) + minorOffset}.0';
}

/// One whole major version ahead of whatever this app was tested against.
String _majorAhead() {
  final parts = ContractCheck.testedAgainst.split('.');
  return '${int.parse(parts[0]) + 1}.0.0';
}

void main() {
  group('agreement', () {
    test('the version the goldens came from agrees with itself', () {
      final check = ContractCheck.of(ContractCheck.testedAgainst);
      expect(check.agreement, ContractAgreement.agreed);
      expect(check.message, isNull, reason: 'agreement draws no notice');
      expect(check.isWarning, isFalse);
    });

    test('a patch release is the same contract', () {
      // nestwatch is pre-1.0: minor carries the breaking changes, patch carries fixes.
      // Warning on a patch bump would put a notice on a parent's screen for a release
      // that cannot have moved anything this app parses.
      final parts = ContractCheck.testedAgainst.split('.');
      final laterPatch = '${parts[0]}.${parts[1]}.99';
      expect(ContractCheck.of(laterPatch).agreement, ContractAgreement.agreed);
    });
  });

  group('disagreement names which side is behind', () {
    test(
      'an older PC is the warning case, because the parent holds the fix',
      () {
        final check = ContractCheck.of(_relative(-1));
        expect(check.agreement, ContractAgreement.serverOlder);
        expect(check.isWarning, isTrue);
        expect(check.message, contains('Updating nestwatch'));
        expect(
          check.message,
          contains(_relative(-1)),
          reason:
              'a parent has to be able to repeat back what their PC reported',
        );
      },
    );

    test('a newer PC says so without alarm — this app is the stale one', () {
      final check = ContractCheck.of(_relative(1));
      expect(check.agreement, ContractAgreement.serverNewer);
      expect(check.isWarning, isFalse);
      expect(check.message, isNotNull);
      expect(check.message, contains('this app that is behind'));
    });

    test('a major bump is a disagreement, not a rounding difference', () {
      expect(
        ContractCheck.of(_majorAhead()).agreement,
        ContractAgreement.serverNewer,
      );
    });

    test('the two directions are not the same sentence', () {
      expect(
        ContractCheck.of(_relative(-1)).message,
        isNot(ContractCheck.of(_relative(1)).message),
        reason: 'the actions are opposite: update that PC, or update this app',
      );
    });
  });

  group('could not check is its own outcome', () {
    // The whole reason for a three-valued verdict. A two-valued one folds every case
    // below into "agreed", which is the shape of check this repo keeps catching in
    // itself: it stops being able to compare, and goes on reporting success.
    test(
      'the literal fallback SessionInfo uses is unreadable, not agreement',
      () {
        // nestwatch_api.dart parses `json['version'] as String? ?? 'unknown'`.
        final check = ContractCheck.of('unknown');
        expect(check.agreement, ContractAgreement.unreadable);
        expect(check.isWarning, isFalse);
        expect(check.message, contains('could not check'));
      },
    );

    for (final raw in ['', '3', 'v0.3.0', '0.x.0', '  ']) {
      test('"$raw" cannot be compared', () {
        expect(
          ContractCheck.of(raw).agreement,
          ContractAgreement.unreadable,
          reason:
              'anything that is not two dotted numbers leaves a parent '
              'exactly where a missing version does',
        );
      });
    }

    test('unreadable never renders as silence', () {
      expect(ContractCheck.of('unknown').message, isNotNull);
    });
  });

  test('surrounding whitespace does not defeat the comparison', () {
    expect(
      ContractCheck.of(' ${ContractCheck.testedAgainst} ').agreement,
      ContractAgreement.agreed,
    );
  });
}
