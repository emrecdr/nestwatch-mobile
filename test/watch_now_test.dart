import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/background/poll_logic.dart';
import 'package:nestwatch_mobile/src/background/watch_now.dart';

void main() {
  group('the Android 15 dataSync budget', () {
    // The system allows dataSync a total of 6 hours per 24, shared across every service
    // the app runs, counted while the app is in the background. Exceeding it calls
    // Service.onTimeout(int, int) and then throws RemoteServiceException.
    const dailyBudget = Duration(hours: 6);

    test('a session ends well inside the daily allowance', () {
      expect(watchSessionLimit, lessThan(dailyBudget));
      // Not merely under it: several sessions must fit in a day, or the first watch of
      // the morning would leave the evening with nothing.
      expect(watchSessionLimit * 4, lessThanOrEqualTo(dailyBudget));
    });

    test('at least four sessions fit in one day', () {
      final sessions = dailyBudget.inMinutes ~/ watchSessionLimit.inMinutes;
      expect(sessions, greaterThanOrEqualTo(4), reason: '$sessions per day');
    });
  });

  group('cadence', () {
    test('watching polls faster than the baseline, by a wide margin', () {
      expect(watchPollInterval, lessThan(pollInterval));
      expect(watchPollInterval, const Duration(seconds: 60));
      expect(pollInterval, const Duration(minutes: 15));
    });

    test(
      'and matches the dashboard, so an open browser and a watching phone agree',
      () {
        // _pollMs in nestwatch assets/app.js is 60000.
        expect(watchPollInterval.inMilliseconds, 60000);
      },
    );
  });
}
