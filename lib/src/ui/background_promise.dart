/// What this app can honestly promise about hearing from that PC, per platform.
///
/// ## Why this is not one sentence
///
/// The baseline tier says "checked about every fifteen minutes", and on Android that is
/// true and carefully chosen: WorkManager's floor is fifteen minutes and anything shorter
/// is silently clamped, so the copy names the floor rather than implying immediacy.
///
/// **On iOS none of that holds.** `workmanager_apple` schedules a `BGAppRefreshTask`, and
/// Apple's contract is explicitly advisory: the interval is a *minimum*, not a promise,
/// and the system decides when — or whether — to run it, from battery state and how the
/// person actually uses the app. Two consequences a parent has to be told about:
///
///   * it may be far longer than fifteen minutes, and there is no number this app can
///     name that would be true;
///   * **swiping the app away stops it entirely.** iOS reads a force-quit as "this app
///     should do nothing", and stops scheduling until the app is opened again.
///
/// Apple's own answer for guaranteed delivery is a push notification with
/// `content-available`. This design forbids it — push needs the *server* to reach Apple,
/// and the monitored PC makes no outbound connection at all. PLAN §7 calls that
/// "not deferred, it is impossible", and it is the reason the honest iOS sentence is
/// weaker rather than merely differently worded.
///
/// Kept out of the widget so it can be read and tested without one, and so the two
/// platforms' promises sit side by side where they can be compared.
library;

import 'dart:io' show Platform;

/// Whether background delivery is dependable enough to name an interval.
bool get backgroundIsSchedulable => Platform.isAndroid;

/// The sentence under the baseline switch.
String backgroundCadenceLine(int minutes) => Platform.isIOS
    ? 'Checked in the background when iOS allows it.'
    : 'Checked about every $minutes minutes.';

/// The paragraph explaining what the switch really buys.
String backgroundCaveat(int minutes) => Platform.isIOS
    ? 'iOS decides when an app that is not running may check, and it does not promise '
          'an interval — it can be much longer than $minutes minutes, and if you swipe '
          'this app away it stops checking altogether until you open it again. Making '
          'this dependable would need a cloud service, which is the one thing this '
          'design does not have. If you are waiting for an answer, open the app — the '
          'Requests screen checks every minute while it is on screen.'
    : 'Android will not check more often than every $minutes minutes for an app that '
          'is not running, so this is a heads-up rather than an alert. If you are '
          'waiting for an answer, open this app — the Requests screen checks every '
          'minute while it is on screen.';

/// Whether the opt-in "watch now" tier can exist on this platform.
///
/// It is a `dataSync` foreground service, and iOS has no equivalent — an app cannot keep
/// polling for half an hour from the background because the parent asked it to. Hiding the
/// control is the honest move; offering a switch that silently does nothing is the exact
/// failure this codebase keeps finding elsewhere.
bool get watchNowIsPossible => Platform.isAndroid;
