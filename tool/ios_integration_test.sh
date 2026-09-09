#!/usr/bin/env bash
# Run the iOS integration tests on a simulator, and believe the app rather than a harness.
#
# `integration_test/pinning_on_ios_test.dart` answers the one question about the pin that the
# host suite cannot: whether App Transport Security sits in `dart:io`'s path. It has to run
# inside a real iOS app to answer it. This script is how that happens in CI.
#
# ## Why not `flutter test integration_test`
#
# That is the obvious way, it works on a Mac here, and it is the right thing to run by hand.
# What it cannot be is the gate. It launches the app with `--disable-vm-service-publication`
# and then discovers the Dart VM Service by scraping the simulator's unified log for the port
# the app printed. On a hosted macOS runner that step stalls: the app starts and gets a pid,
# and `Waiting for VM Service port to be available...` never returns. Four CI runs in
# September 2026: two green in about seven minutes, two hung until the job timeout. It has
# never once failed on this Mac, which is what makes it untreatable by guessing. Upstream has
# the same wall reported by people who are not us -- flutter/flutter#136222, #144926, #154685.
#
# ## Why not the XCTest route Flutter documents for CI
#
# `INTEGRATION_TEST_IOS_RUNNER` reflects each Dart test into a native XCTest case, with no
# host side at all, and it is the right shape for this problem. It was built and measured
# here on 2026-09-09 and it does not work on this toolchain: the bundle loads, the app runs,
# the Dart tests pass -- and `+testInvocations` yields zero cases, so `xcodebuild` prints
# `** TEST SUCCEEDED **` and exits 0 having run nothing. Three candidate explanations were
# tested and all three refuted; see `M32`. Being unable to explain it is exactly why it is
# not the gate.
#
# ## What this does instead
#
# Launches the app and reads what the Dart test reporter prints. No VM Service, no port, no
# XCTest discovery -- the two mechanisms above are the two that break, and neither is here.
# The reporter's output is the same text a person reads when running the tests by hand.
#
# That means this script's whole job is to not be fooled by silence, because the failure mode
# of every route tried so far has been a green result with nothing behind it.
#
#   0  the tests ran and passed
#   1  the tests ran and something failed -- or too few of them ran to mean anything
#   2  could not look: no simulator, or no build, or the app never said anything
#
# Exit 2 is not a pass. docs/VERSIONING.md has the convention; CI treats it as failure here,
# because on a hosted runner a missing simulator means the runner is broken, not that the
# question is unanswerable.
set -uo pipefail
cd "$(dirname "$0")/.."

TEST_TARGET="${1:-integration_test/pinning_on_ios_test.dart}"
BUNDLE_ID="com.nestwatch.mobile"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-120}"

# **The vacuity guard, and it is deliberately a hard-coded number.**
#
# The tempting version counts `test(` in the Dart file and compares. That check cannot fail:
# delete a test and both sides move together, which is the shape `M26` is about -- a test
# whose input derives from the thing under test cannot see it change. So the number lives
# here, and adding or removing a test means editing this line on purpose.
#
# Five tests plus the `tearDownAll` the reporter counts as one more. Requiring at least the
# five is what makes "All tests passed!" mean something: that line is printed just as happily
# by a run that executed nothing at all.
MIN_TESTS=5

say() { echo "$@" >&2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------
# A simulator, or an honest refusal.
# ---------------------------------------------------------------------------------
udid="$(bash tool/boot_simulator.sh)" || {
  say "No simulator was available, so nothing was checked."
  say "That is not a statement about the pin."
  exit 2
}
say "Simulator: $udid"

# ---------------------------------------------------------------------------------
# Build the app with the integration test as its entrypoint.
# ---------------------------------------------------------------------------------
say "Building $TEST_TARGET for the simulator..."
if ! flutter build ios --simulator --debug "$TEST_TARGET" > "$WORK/build.log" 2>&1; then
  say "The build failed. Nothing was tested."
  tail -30 "$WORK/build.log" >&2
  exit 2
fi

APP="build/ios/iphonesimulator/Runner.app"
if [ ! -d "$APP" ]; then
  say "The build reported success but $APP is not there."
  exit 2
fi

# The app's Dart entrypoint has to actually be the test. `--simulator --debug` keeps the Dart
# code as a kernel blob, so this is checkable rather than assumed -- and it is worth checking,
# because an app built from `lib/main.dart` launches perfectly and reports nothing, which
# reaches the same silence this whole script is written against.
#
# `grep -c` rather than `grep -q`, and it matters. `grep -q` exits the moment it matches,
# which sends SIGPIPE to `strings` part-way through a 73 MB blob, which under the
# `pipefail` set at the top of this file makes the whole pipeline report failure -- on
# success. That cost a run: the guard fired against a correctly built app. `-c` reads to
# the end and has nothing to race with.
BLOB="$APP/Frameworks/App.framework/flutter_assets/kernel_blob.bin"
binding_hits=$(strings "$BLOB" 2>/dev/null | grep -c "IntegrationTestWidgetsFlutterBinding")
if [ -f "$BLOB" ] && [ "${binding_hits:-0}" -eq 0 ]; then
  say "The built app does not contain the integration test binding."
  say "It was built from a different entrypoint, and would have run and said nothing."
  exit 2
fi

# ---------------------------------------------------------------------------------
# Run it, and read what it says.
# ---------------------------------------------------------------------------------
xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$udid" "$APP" || { say "Could not install the app."; exit 2; }

# **The Dart reporter's output arrives in the unified log, not on the launch's stdout.**
#
# `simctl launch --console-pty` looks like the way to read it and is not: it prints the pid
# and then nothing, because Flutter's `print` goes to `os_log` rather than to the file
# descriptors the launch attached. Measured here -- an app whose tests were passing gave one
# line of output, and the first version of this script read that as silence and exited 2.
#
# So the log stream is started *first* and given a moment to attach. Starting it after the
# launch loses the beginning of the run, which is most of it: these tests finish in about
# half a second.
RAW="$WORK/stream.log"
OUT="$WORK/reporter.log"
: > "$RAW"; : > "$OUT"

xcrun simctl spawn "$udid" log stream --style compact \
  --predicate 'processImagePath CONTAINS "Runner"' > "$RAW" 2>&1 &
stream_pid=$!
sleep 3

xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || {
  kill "$stream_pid" 2>/dev/null
  say "The app would not launch."
  exit 2
}

say "Running, with a ${LAUNCH_TIMEOUT}s ceiling..."
elapsed=0
while [ "$elapsed" -lt "$LAUNCH_TIMEOUT" ]; do
  if grep -qE "All tests passed!|Some tests failed" "$RAW" 2>/dev/null; then break; fi
  sleep 1
  elapsed=$((elapsed + 1))
done

kill "$stream_pid" 2>/dev/null
wait "$stream_pid" 2>/dev/null
xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1

# Keep only what the Dart reporter said. Everything before `flutter: ` on those lines is the
# log's own framing, and it carries timestamps like `+0200` that a `+[0-9]+` count would
# read as a test number -- the parse below has to see the reporter's words and nothing else.
sed -n 's/.*flutter: //p' "$RAW" > "$OUT" 2>/dev/null || true

# ---------------------------------------------------------------------------------
# Decide, and refuse to call silence a pass.
# ---------------------------------------------------------------------------------
echo
sed 's/^/  /' "$OUT"
echo

# The reporter prints one line per test, `+N` counting completions and `-N` failures. The
# highest `+N` seen is how many actually ran; anything that stops early stops the count with
# it, which is the point.
ran=$(grep -oE '\+[0-9]+' "$OUT" 2>/dev/null | sed 's/+//' | sort -n | tail -1)
ran=${ran:-0}
failed=$(grep -oE '\-[0-9]+' "$OUT" 2>/dev/null | sed 's/-//' | sort -n | tail -1)
failed=${failed:-0}

if [ ! -s "$OUT" ]; then
  say "The app produced no test output at all in ${LAUNCH_TIMEOUT}s."
  say "Nothing was checked. This is not a pass, and it is not a failure of the pin --"
  say "it means the app never got as far as saying anything."
  exit 2
fi

if grep -q "Some tests failed" "$OUT" 2>/dev/null || [ "$failed" -gt 0 ]; then
  say "FAILED: $failed of $ran reported tests failed on iOS."
  exit 1
fi

if ! grep -q "All tests passed!" "$OUT" 2>/dev/null; then
  say "The app started and spoke, but never reached a verdict within ${LAUNCH_TIMEOUT}s."
  say "$ran test(s) had reported when it stopped. Treating an unfinished run as a failure."
  exit 1
fi

if [ "$ran" -lt "$MIN_TESTS" ]; then
  say "'All tests passed!' -- but only $ran test(s) ran, and this file expects at least"
  say "$MIN_TESTS. A run that executes nothing prints that same line. Refusing to pass."
  exit 1
fi

say "$ran test(s) ran on iOS $udid, all passed."
exit 0

# Three outcomes, and the third earns its own code rather than being folded into either of
# the others: 0 the pin holds on iOS, 1 it does not or too little ran to say, 2 nothing was
# looked at. See docs/VERSIONING.md, and `tool/check_findings.sh` for the same discipline
# applied to a question this repository also cannot always answer.
