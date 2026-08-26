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

echo
if [ "$drift" -eq 0 ]; then
  echo "$checked checks, nothing drifted."
else
  echo "$drift of $checked drifted. Fix them, then re-run flutter test —"
  echo "the point is to find out what the change breaks, not to make the diff go away."
fi
exit "$drift"
