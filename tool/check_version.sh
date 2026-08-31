#!/usr/bin/env bash
# Do the version numbers agree with each other?
#
# Four places can disagree: `pubspec.yaml`, `CHANGELOG.md`, the git tag, and -- separately
# and for a different reason -- `ContractCheck.testedAgainst`. See docs/VERSIONING.md.
#
# Like the other checkers here, this has three outcomes rather than two. Asked about a tag
# on a checkout that has none, it says so and exits 2 instead of reporting a pass: "no tag
# to disagree with" and "the tag agrees" are different answers and a release gate that
# blurs them is how an unreleased build acquires a version nobody chose.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
say() { printf '  %-12s %s\n' "$1" "$2"; }

# --- pubspec, the source of truth for the marketing version -------------------------
pubspec=$(sed -n 's/^version: \([0-9][0-9.]*\)+\([0-9][0-9]*\).*/\1 \2/p' pubspec.yaml | head -1)
name=${pubspec%% *}
build=${pubspec##* }
if [ -z "$name" ] || [ -z "$build" ] || [ "$name" = "$build" ]; then
  say UNREADABLE "pubspec.yaml has no 'version: X.Y.Z+N' line this can parse."
  echo; echo "Nothing below was checked, because the version everything is compared to is"
  echo "the thing that could not be read."
  exit 2
fi
case "$name" in
  [0-9]*.[0-9]*.[0-9]*) say "pubspec" "$name+$build" ;;
  *) say BAD "version '$name' is not MAJOR.MINOR.PATCH"; status=1 ;;
esac

# --- changelog ----------------------------------------------------------------------
if [ ! -f CHANGELOG.md ]; then
  say MISSING "CHANGELOG.md does not exist"
  status=1
else
  # The newest released heading, ignoring [Unreleased].
  top=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)
  if [ -z "$top" ]; then
    say "changelog" "no released version yet (only [Unreleased]) — consistent with 0.x"
  elif [ "$top" = "$name" ]; then
    say "changelog" "$top matches pubspec"
  else
    say MISMATCH "CHANGELOG's newest release is $top, pubspec says $name"
    status=1
  fi
  grep -q '^## \[Unreleased\]' CHANGELOG.md ||
    { say MISSING "CHANGELOG.md has no '## [Unreleased]' section"; status=1; }
fi

# --- the tag, when there is one ------------------------------------------------------
# `--exact-match` so this speaks only about a tagged commit. A checkout that is merely
# *descended* from v0.1.0 is not a release of it.
tag=$(git describe --tags --exact-match 2>/dev/null)
if [ -z "$tag" ]; then
  say "tag" "this commit is not tagged — nothing to compare (not a pass)"
  tag_checked=0
else
  tag_checked=1
  if [ "$tag" = "v$name" ]; then
    say "tag" "$tag matches pubspec"
  else
    say MISMATCH "tagged $tag but pubspec says $name"
    status=1
  fi
fi

# --- the contract version, which is NOT the app's ------------------------------------
# Reported rather than compared: it tracks nestwatch's releases, not this app's, and the
# two being equal would be a coincidence. Printed so a release note can quote it without
# anyone going to read the Dart.
contract=$(sed -n "s/.*testedAgainst = '\([^']*\)'.*/\1/p" lib/src/api/server_contract.dart | head -1)
if [ -z "$contract" ]; then
  say UNREADABLE "could not read ContractCheck.testedAgainst"
  status=1
else
  say "contract" "golden files captured from nestwatch $contract (independent of the above)"
fi

echo
if [ "$status" -ne 0 ]; then
  echo "Versions disagree. See docs/VERSIONING.md."
  exit 1
fi
if [ "$tag_checked" -eq 0 ]; then
  echo "Everything checkable agrees; the tag was not among it."
  exit 0
fi
echo "App $name+$build, tagged, changelog and contract all agree."
