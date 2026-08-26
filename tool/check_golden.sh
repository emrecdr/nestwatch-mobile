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

# ---------------------------------------------------------------------------------
# Constants this app mirrors but no golden file carries.
# ---------------------------------------------------------------------------------
#
# `test/time_code_test.dart` pins these against literals, which is right and is also only
# half of it: it pins *this* app's constant against *this* app's literal. If nestwatch
# moves MAX_CODE_MINUTES to 300, that test still passes and the screen goes on telling a
# parent "1 to 240" while the PC accepts 300.
#
# The code length needs nothing here. Its golden sample is generated from CODE_LEN, so a
# change drifts time-codes.json above and the length assertion fails on the copy. These
# two appear in no golden file, so there is nothing to drift.
#
# A constant that cannot be found must read as an error, never as agreement. Renaming
# MAX_ACTIVE_CODES would otherwise turn this whole section into eight quiet "same" lines.

echo
echo "Constants mirrored from $SRC/src/timecode.rs"
echo

rust_const() { grep -hoE "\\b$2\\b *: *[a-z0-9]+ *= *[0-9]+" "$1" 2>/dev/null | grep -oE '[0-9]+$' | head -1; }
dart_const() { grep -hoE "\\b$2\\b *= *[0-9]+" "$1" 2>/dev/null | grep -oE '[0-9]+$' | head -1; }

compare_const() {
  local theirs_file="$1" theirs_name="$2" mine_file="$3" mine_name="$4"
  local t m
  t=$(rust_const "$theirs_file" "$theirs_name")
  m=$(dart_const "$mine_file" "$mine_name")

  if [ -z "$t" ]; then
    echo "  UNREADABLE    $theirs_name not found in $theirs_file — renamed, or moved."
    echo "                Nothing was compared. This is not agreement."
    drift=$((drift + 1))
  elif [ -z "$m" ]; then
    echo "  UNREADABLE    $mine_name not found in $mine_file."
    drift=$((drift + 1))
  elif [ "$t" != "$m" ]; then
    echo "  DISAGREES     $mine_name is $m here, $theirs_name is $t there"
    drift=$((drift + 1))
  else
    echo "  same          $mine_name = $m"
  fi
  checked=$((checked + 1))
}

compare_const "$SRC/src/timecode.rs" MAX_CODE_MINUTES lib/src/api/models.dart maxMinutes
compare_const "$SRC/src/timecode.rs" MAX_ACTIVE_CODES lib/src/api/models.dart maxActive

# The login limiter has no named constant over there — it is built inline in
# `impl Default for LoginLimiter`. So this reads the call arguments, which is more
# fragile than a constant name and deliberately so: any refactor of that line reports
# UNREADABLE rather than agreeing about something it stopped being able to see.
echo
echo "Login limiter, from $SRC/src/auth.rs"
echo

limiter=$(grep -hoE 'Self::new\([0-9]+, *Duration::from_secs\([0-9]+\)\)' "$SRC/src/auth.rs" 2>/dev/null | head -1)
if [ -z "$limiter" ]; then
  echo "  UNREADABLE    LoginLimiter::default not in the shape this expects."
  echo "                Nothing was compared. This is not agreement."
  drift=$((drift + 1))
  checked=$((checked + 1))
else
  their_attempts=$(echo "$limiter" | grep -oE '\([0-9]+,' | grep -oE '[0-9]+')
  their_lockout=$(echo "$limiter" | grep -oE 'from_secs\([0-9]+\)' | grep -oE '[0-9]+')
  my_attempts=$(dart_const lib/src/api/models.dart maxAttempts)
  my_lockout=$(grep -hoE 'lockout = Duration\(seconds: [0-9]+\)' lib/src/api/models.dart | grep -oE '[0-9]+')

  for pair in "maxAttempts:$my_attempts:$their_attempts" "lockout secs:$my_lockout:$their_lockout"; do
    label=${pair%%:*}; rest=${pair#*:}; mine=${rest%%:*}; theirs=${rest#*:}
    checked=$((checked + 1))
    if [ -z "$mine" ] || [ -z "$theirs" ]; then
      echo "  UNREADABLE    $label could not be read on one side. Not agreement."
      drift=$((drift + 1))
    elif [ "$mine" != "$theirs" ]; then
      echo "  DISAGREES     $label is $mine here, $theirs there"
      drift=$((drift + 1))
    else
      echo "  same          $label = $mine"
    fi
  done
fi

echo
if [ "$drift" -eq 0 ]; then
  echo "$checked checks, nothing drifted."
else
  echo "$drift of $checked drifted. Fix them, then re-run flutter test —"
  echo "the point is to find out what the change breaks, not to make the diff go away."
fi
exit "$drift"
