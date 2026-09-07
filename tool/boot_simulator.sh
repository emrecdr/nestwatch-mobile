#!/usr/bin/env bash
# Boot an iOS simulator and say which one, so the integration test has somewhere to run.
#
# `integration_test/pinning_on_ios_test.dart` drives a real TLS handshake inside a running
# iOS app, and its first test refuses to run anywhere else — `Platform.operatingSystem` has
# to be `ios` or `android`, because on the host the whole file would pass and prove nothing
# about the platform it is named after. So something must choose a device. On a developer's
# machine that is a person; in CI it is this.
#
# Prints the udid on **stdout** and its reasoning on **stderr**, so a caller can write
#
#     udid=$(bash tool/boot_simulator.sh)
#
# and still have the explanation in the log next to whatever happened afterwards.
#
# ## Why this is a script rather than four lines of YAML
#
# `docs/OPEN-FINDINGS.md` M30 asked for this job on 2026-09-05 and said in the same breath
# why it had not been built: "a new job that fails for setup reasons rather than for the
# property it checks is exactly the illegible red badge M25 argues against". That is the
# real risk here — a red `pin holds · ios simulator` that actually means *this runner had
# no simulator* reads exactly like one that means *the pin does not hold on iOS*, and those
# are not remotely the same news.
#
# A recipe that lives inside a workflow can only be rehearsed by pushing it. One that lives
# here runs on the machine of whoever is about to change it, which is the whole reason the
# other four `tool/*.sh` gates are scripts too.
#
# ## Newest available, rather than named
#
# Hard-coding `iPhone 17 Pro` reds the job the week GitHub refreshes its image, for a reason
# that has nothing to do with pinning. Measured 2026-09-08 against the published inventory
# for `macos-latest` (macOS 26 arm64): it carries iOS 26.0 through 26.5 with iPhone 17 Pro
# and friends pre-created under each. This takes an iPhone from the newest runtime that is
# actually available and names it, so the log records which device answered.
#
# ## Two outcomes, and the second is a real answer
#
#   0  booted; udid on stdout
#   2  there is no simulator here — said in those words, so that a caller can tell "nothing
#      was tested" from "the thing under test failed". Same third-outcome discipline as
#      check_golden.sh and check_findings.sh, and for the same reason: a gate that cannot
#      say "I could not look" eventually says "fine" instead.
set -uo pipefail

say() { echo "$@" >&2; }

if ! command -v xcrun >/dev/null 2>&1; then
  say "No xcrun on this machine, so there is no simulator to boot."
  say "Nothing was tested. This is not a statement about the pin."
  exit 2
fi

devices=$(xcrun simctl list devices available --json 2>/dev/null)
if [ -z "$devices" ]; then
  say "\`xcrun simctl list devices available\` returned nothing."
  say "Nothing was tested. This is not a statement about the pin."
  exit 2
fi

# Runtime keys look like `com.apple.CoreSimulator.SimRuntime.iOS-26-5`; the version is the
# tail, and it is compared as numbers rather than as text so that 26.5 beats 18.2 and 26.10
# would beat 26.9. Python because `tool/` already has two .py files and because getting
# this wrong in awk is a quieter mistake than getting it wrong here.
picked=$(printf '%s' "$devices" | python3 -c '
import json, sys

runtimes = json.load(sys.stdin)["devices"]
best_version, best_device = (), None
for runtime, devices in runtimes.items():
    if ".iOS-" not in runtime:
        continue
    try:
        version = tuple(int(part) for part in runtime.split(".iOS-")[1].split("-"))
    except ValueError:
        continue
    if version <= best_version:
        continue
    iphones = [d for d in devices
               if d.get("isAvailable") and d.get("name", "").startswith("iPhone")]
    if iphones:
        best_version, best_device = version, iphones[0]

if best_device is None:
    sys.exit(1)
print(best_device["udid"], ".".join(str(p) for p in best_version), best_device["name"])
')

if [ -z "$picked" ]; then
  say "There are iOS runtimes here, but no available iPhone simulator under any of them."
  say "Nothing was tested. This is not a statement about the pin."
  exit 2
fi

read -r udid version name <<< "$picked"
say "Booting $name on iOS $version ($udid)"

# An already-booted device is the normal case on a developer's machine and simctl calls it
# an error, so the message is read rather than the exit code. The match is deliberately
# loose: if Apple rewords it and a genuine failure slips through here, `bootstatus` below
# is the backstop and fails properly. Guessing wrong in the other direction — a tightened
# pattern that stops matching — would fail every run on a machine that already had the
# simulator open, which is most of them.
if ! boot_output=$(xcrun simctl boot "$udid" 2>&1); then
  if ! printf '%s' "$boot_output" | grep -q 'Booted'; then
    say "Could not boot it: $boot_output"
    say "Nothing was tested. This is not a statement about the pin."
    exit 2
  fi
  say "  (already booted)"
fi

# Boot returns before the device is usable, and `flutter test -d` against a half-booted
# simulator fails in a way that looks like the app crashing.
if ! xcrun simctl bootstatus "$udid" -b >&2; then
  say "It never finished booting."
  say "Nothing was tested. This is not a statement about the pin."
  exit 2
fi

echo "$udid"
