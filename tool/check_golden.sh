#!/usr/bin/env bash
# Are the vendored golden files still what nestwatch produces?
#
# `test/golden/` holds copies, so `flutter test` runs on a machine that has this repo and
# nothing else. The cost of a copy is that it can drift; this is what catches that.
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
  echo "$checked files, none drifted."
else
  echo "$drift of $checked drifted. Copy them across, then re-run flutter test —"
  echo "the point is to find out what the change breaks, not to make the diff go away."
fi
exit "$drift"
