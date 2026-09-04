/// What this phone calls itself, in the one list where a parent decides what to revoke.
///
/// nestwatch 0.7.0's *Signed-in devices* card renders `auth::remember_device`'s stored
/// user agent beside a **Sign out** button for that row. This app sent none, so `dart:io`
/// supplied `Dart/3.12 (dart:io)` — captured off the wire, with a control request
/// carrying a known string to prove the sink reported what was actually sent.
///
/// The shape is asserted here; that the version inside it still matches `pubspec.yaml` is
/// asserted by `tool/check_version.sh`, which is where the other four version copies are
/// already held to each other, and which CI runs as its own job.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/client_identity.dart';

void main() {
  test('it names this app, not the language it happens to be written in', () {
    final ua = userAgentFor('android');
    expect(ua, contains('nestwatch-mobile'));
    expect(
      ua.toLowerCase(),
      isNot(contains('dart')),
      reason:
          'the default said only which SDK built it, which is the defect this closes — '
          'and it moved when the SDK was upgraded, changing a row a parent was trying '
          'to recognise',
    );
  });

  test('it carries the app version, so a row names a build', () {
    expect(userAgentFor('android'), contains(appVersion));
  });

  test('it says which platform, and is built from one rather than reading one', () {
    // Pure, so this states the shape without asserting on whichever machine runs it. A
    // test that compared against `Platform.operatingSystem` would pass on CI and on a
    // laptop for two different reasons, and would still pass if the argument were
    // ignored entirely.
    expect(userAgentFor('android'), 'nestwatch-mobile/$appVersion (android)');
    expect(userAgentFor('ios'), 'nestwatch-mobile/$appVersion (ios)');
  });

  test('it stays inside the length nestwatch will keep', () {
    // `MAX_USER_AGENT` in nestwatch `src/auth.rs` truncates at 256 characters, on the way
    // into a file the session store rewrites whole. Nothing here is near it; the
    // assertion exists so that a future addition — a device model, a build number — is
    // measured against that bound rather than discovering it by being cut in half in
    // front of a parent.
    expect(userAgentFor('android').length, lessThan(256));
  });
}
