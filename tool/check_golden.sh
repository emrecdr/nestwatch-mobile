#!/usr/bin/env bash
# Are the vendored golden files still what nestwatch produces?
#
# `test/golden/` holds copies, so `flutter test` runs on a machine that has this repo and
# nothing else. The cost of a copy is that it can drift; this is what catches that.
#
# It used to do a second job: grepping nestwatch's Rust for the constants a phone renders
# before it can ask — "1 to 240 minutes", "5 tries, then a minute". That channel is gone.
# nestwatch publishes them as `limits.json` now, so they are vendored like every other
# golden file and asserted in `test/models_golden_test.dart`, which runs on every commit
# rather than whenever somebody remembers to point this at a sibling checkout.
#
# Worth recording why the grep had to go, because it never reported a wrong number. It
# stopped being able to report anything: the constants were given names on that side —
# an improvement there — and the reader looking for the old inline shape found nothing,
# hours after it was written. A checker whose failure mode is "it stopped checking" is
# worse than one that is merely wrong, and the only reason it was caught is that it had
# been built to shout when it could not read rather than to shrug.
#
# Not part of `flutter test` on purpose. Wiring it in would mean skipping wherever
# nestwatch is absent, and a check that quietly stops running reports success either way —
# which is how this repo lost a mutation for a while: the anchor stopped matching, the
# count went 24 to 23, and the audit still said survived=0.
set -uo pipefail
cd "$(dirname "$0")/.."

SRC="${NESTWATCH_REPO:-../nestwatch}"
MINE="test/golden"

if [ ! -d "$SRC/tests/golden" ]; then
  echo "nestwatch not found at $SRC"
  echo
  echo "  Nothing was checked. The copies in $MINE may be stale and this script"
  echo "  cannot tell. Set NESTWATCH_REPO to the checkout and run again."
  exit 2
fi

echo "Comparing $MINE against $SRC/tests/golden ($(cd "$SRC" && git rev-parse --short HEAD))"
echo


# Compare one value read from each side, with the third outcome spelled out.
#
# Two of these existed written out, and a third would have been a third copy of the same
# three branches — which is how the shapes drift apart and one of them quietly loses its
# unreadable case. The argument order is (label, theirs, mine, advice).
#
# Empty on either side is UNREADABLE, never agreement: a reader that found nothing has
# compared nothing, and that is the failure this whole script exists to make loud.
compare() {
  local label="$1" theirs="$2" mine="$3" advice="$4"
  if [ -z "$theirs" ] || [ -z "$mine" ]; then
    echo "  UNREADABLE    $label: nestwatch=[${theirs:-?}] here=[${mine:-?}]"
    echo "                One of the two readers found nothing. Nothing was compared --"
    echo "                fix the reader, do not assume they agree."
    drift=$((drift + 1))
  elif [ "$theirs" != "$mine" ]; then
    echo "  DRIFTED       $label: nestwatch=$theirs, here=$mine"
    echo "                $advice"
    drift=$((drift + 1))
  else
    echo "  same          $label ($mine)"
    checked=$((checked + 1))
  fi
}

drift=0
checked=0

for theirs in "$SRC"/tests/golden/*.json; do
  name=$(basename "$theirs")
  mine="$MINE/$name"
  checked=$((checked + 1))
  if [ ! -f "$mine" ]; then
    echo "  MISSING HERE  $name — nestwatch has a shape this app never parses"
    drift=$((drift + 1))
  elif ! diff -q "$theirs" "$mine" >/dev/null; then
    echo "  DRIFTED       $name"
    diff -u "$mine" "$theirs" | sed 's/^/                /'
    drift=$((drift + 1))
  else
    echo "  same          $name"
  fi
done

# The other direction matters too: a file here that nestwatch dropped is a contract this
# app is still testing itself against and nothing is producing any more.
for mine in "$MINE"/*.json; do
  name=$(basename "$mine")
  if [ ! -f "$SRC/tests/golden/$name" ]; then
    echo "  ORPHANED      $name — nestwatch no longer produces this"
    drift=$((drift + 1))
  fi
done

# The version those files were captured from, which the app renders a warning against.
#
# This is a second reader of nestwatch's source, and the last one had to be deleted -- it
# looked for inline numeric literals that were later given names, and went quiet rather
# than wrong. The distinction that makes this one survivable is that `version` under
# `[package]` is not a name anybody chose: cargo requires that exact key, and renaming it
# breaks the build on that side long before it can mislead this one. It still shouts if it
# cannot read, because "the reader broke" and "the versions agree" must never look alike.
theirs_version=$(sed -n '/^\[package\]/,/^\[/p' "$SRC/Cargo.toml" 2>/dev/null |
  sed -n 's/^version = "\([^"]*\)".*/\1/p' | head -1)
mine_version=$(sed -n "s/.*testedAgainst = '\([^']*\)'.*/\1/p" \
  lib/src/api/server_contract.dart | head -1)

echo
# major.minor only, matching ContractCheck's own rule -- a patch bump on that side cannot
# move the wire format, and failing here would be noise.
compare "version" "${theirs_version%.*}" "${mine_version%.*}" \
  "The app will tell a parent the two disagree. If these golden files are current, bump testedAgainst with them."

# The renewal threshold the phone warns at, which must be the one nestwatch warns at.
#
# nestwatch's own comment says RENEW_WARN_DAYS is `pub` so that `doctor` "nags at the same
# threshold as the service log". A phone disagreeing with both would be a third answer.
theirs_warn=$(sed -n 's/^pub const RENEW_WARN_DAYS: u64 = \([0-9]*\);.*/\1/p' \
  "$SRC/src/cert.rs" 2>/dev/null | head -1)
mine_warn=$(sed -n 's/^const int renewWarnDays = \([0-9]*\);.*/\1/p' \
  lib/src/pinning/certificate_expiry.dart | head -1)

echo
compare "renew warning (days)" "$theirs_warn" "$mine_warn" \
  "A parent would get two answers to the same question."

echo
if [ "$drift" -eq 0 ]; then
  echo "$checked checks, nothing drifted."
  exit 0
fi
echo "$drift of $checked drifted. Fix them, then re-run flutter test —"
echo "the point is to find out what the change breaks, not to make the diff go away."

# Exit 1, not `exit "$drift"`, and the difference is not cosmetic.
#
# This used to return the drift COUNT as its status, which collided with the `exit 2` above
# meaning "could not compare at all". Two drifted files and a missing sibling checkout both
# exited 2, and the caller had no way to tell "the contract moved" from "nothing was
# checked" -- the exact distinction the rest of this file is built around.
#
# It is not hypothetical. On 2026-09-01 a gate script here reported `check_golden.sh exit=2`
# and it was read as the could-not-compare branch; it was in fact 2 of 11 drifted. The
# count belongs in the sentence above, which a person reads. The status is for a caller
# branching on it, and a caller can only act on three answers:
#
#   0  compared, nothing moved
#   1  compared, something moved
#   2  could not compare -- see the exit above
#
# The count also wrapped mod 256, so 256 drifted comparisons would have reported success.
# Unreachable at eleven checks, and still the wrong channel for a number.
exit 1
