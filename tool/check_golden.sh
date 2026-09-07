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

src_sha=$(cd "$SRC" && git rev-parse --short HEAD 2>/dev/null)
echo "Comparing $MINE against $SRC/tests/golden (${src_sha:-unknown commit})"

# Is that commit published, or is it somebody's uncommitted afternoon?
#
# `NESTWATCH_REPO` defaults to `../nestwatch`, which is a WORKING TREE and may hold
# anything: local commits, unpushed work, a half-finished branch. CI clones the pushed
# branch instead, so the same command answers about two different trees and both answers
# are true. Vendoring the golden files from the wrong one produces a repo that passes
# locally and fails in CI, which is exactly what happened on 2026-09-02 -- goldens copied
# out of unpushed work carrying `refused_total`, a field no published nestwatch had.
#
# Read from the local remote-tracking ref rather than the network, so this still works
# offline. That ref can be stale, so this can warn about work that IS pushed; it cannot
# stay silent about work that is not, which is the direction that matters.
has_origin=0
if [ -n "$src_sha" ] && (cd "$SRC" && git rev-parse --verify -q origin/main >/dev/null); then
  has_origin=1
  if ! (cd "$SRC" && git merge-base --is-ancestor HEAD origin/main 2>/dev/null); then
    echo
    echo "  NOTE: $src_sha is not in that checkout's origin/main. You are comparing"
    echo "  against local work. CI clones the pushed branch and will see something else —"
    echo "  do not vendor golden files from here without checking which tree they came from."
    echo "  (If origin/main is merely stale, fetch and re-run.)"
  fi
fi

# **And the half the check above cannot see: an uncommitted file.**
#
# That test asks whether `HEAD` has been pushed. It answers nothing about the working tree
# sitting on top of it, and the loop below globs a *directory* rather than a commit — so a
# golden that exists on disk and in no commit anywhere is compared as though nestwatch
# published it.
#
# Found on 2026-09-06, by this script, reporting `1 of 12 drifted` and exiting 1 because
# `session-integration.json` was untracked in the sibling checkout. `HEAD` was exactly
# `origin/main`, so the warning above stayed correctly silent, and the report was
# confident and wrong. Acting on it means vendoring a golden no published nestwatch has —
# which is the 2026-09-02 failure the warning above was written to prevent, arriving
# through the one path it does not cover.
if [ "$has_origin" = 1 ]; then
  dirty=$(cd "$SRC" && git status --porcelain -- tests/golden/ 2>/dev/null)
  if [ -n "$dirty" ]; then
    echo
    echo "  NOTE: that checkout has uncommitted changes under tests/golden/:"
    echo "$dirty" | sed 's/^/        /'
    echo "  These are in no commit, so CI will not see them. Anything below that rests on"
    echo "  one of these files describes somebody's working tree, not a published server."
  fi
fi
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
# Goldens that exist only in the sibling's working tree. Reported, never counted as
# drift -- see the loop below for why the two want opposite actions.
unpublished=0

for theirs in "$SRC"/tests/golden/*.json; do
  name=$(basename "$theirs")
  mine="$MINE/$name"
  checked=$((checked + 1))
  if [ ! -f "$mine" ]; then
    # Two different situations wearing one message, and they want opposite actions.
    #
    # A golden nestwatch has **published** and this app does not vendor is drift: a shape
    # is on the wire that nothing here parses, and the remedy is to vendor it and decide
    # what reads it.
    #
    # A golden that exists only in that checkout's working tree is not drift at all. It is
    # work in progress, it is in no commit, and vendoring it copies a shape no released
    # server sends. The remedy is to wait. Reported rather than counted, the same way
    # `check_findings.sh` surfaces a cross-repo notification instead of failing on it --
    # failing here would red a gate because somebody else has an editor open.
    if [ "$has_origin" = 1 ] &&
       ! (cd "$SRC" && git cat-file -e "origin/main:tests/golden/$name" 2>/dev/null); then
      echo "  NOT PUBLISHED $name — exists only in that working tree; nothing to vendor yet"
      unpublished=$((unpublished + 1))
    else
      echo "  MISSING HERE  $name — nestwatch has a shape this app never parses"
      drift=$((drift + 1))
    fi
  elif ! diff -q "$theirs" "$mine" >/dev/null; then
    # It differs from that working tree. The question this script exists to answer is
    # whether it differs from what is **published**, because that is the tree CI clones and
    # the only one a released nestwatch corresponds to.
    #
    # Consistency with the untracked case above, which is what forced this: an untracked
    # golden was already reported as "not published yet" rather than counted, on the
    # grounds that failing would red a gate because somebody else has an editor open. A
    # *modified* golden is the same situation and was still counted as drift, which is the
    # same argument reaching the opposite verdict two branches apart.
    if [ "$has_origin" = 1 ] &&
       (cd "$SRC" && git show "origin/main:tests/golden/$name" 2>/dev/null) |
         diff -q - "$mine" >/dev/null 2>&1; then
      echo "  UNCOMMITTED   $name — differs only in that working tree; what is pushed matches"
      # Shown anyway. It is not drift, but it is the shape that is coming, and seeing it
      # early is most of why anybody points this at a working tree in the first place.
      diff -u "$mine" "$theirs" | sed 's/^/                /'
      unpublished=$((unpublished + 1))
    else
      echo "  DRIFTED       $name"
      diff -u "$mine" "$theirs" | sed 's/^/                /'
      drift=$((drift + 1))
    fi
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

# The third fact — the one the two comparisons above cannot supply between them.
#
# The comparison above puts nestwatch's `Cargo.toml` version beside `testedAgainst`. Both
# name **the last release**, so they agree no matter how far `main` has moved past the tag —
# it is one fact checked against itself, and it cannot see the thing it looks like it is
# checking.
#
# It missed exactly that on 2026-09-02, for three days. The goldens were vendored from
# `origin/main`, which was past `v0.6.0` and carrying the unreleased `scope` work.
# `testedAgainst` was set to `0.6.0`. Both were individually defensible, this script agreed,
# CI was green, and the pair described a nestwatch that has never existed as a release: no
# 0.6.0 sends `scope`.
#
# So ask the question neither number can answer — **does the release `testedAgainst` names
# actually produce these files?** — by reading the goldens out of that tag and diffing them
# against the vendored copies. Silent whenever the answer is yes, which is every ordinary
# day including the whole of a development cycle: being past a tag is normal, and warning
# about it would be the noise `M25` argues against. It speaks only when the tag's files and
# these files genuinely differ, which is the moment `testedAgainst` starts lying.
tag="v$mine_version"
if [ -z "$mine_version" ]; then
  echo "  UNREADABLE    testedAgainst: could not read it from server_contract.dart"
  echo "                Nothing was compared against a release."
  drift=$((drift + 1))
elif ! (cd "$SRC" && git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1); then
  # Third outcome, spelled out rather than folded into agreement: a tag that is not in the
  # checkout may simply not have been fetched, and "could not look" is not "they match".
  echo "  UNREADABLE    release $tag: no such tag in that checkout"
  echo "                Nothing was compared against a release. \`git fetch --tags\` there,"
  echo "                or the tag does not exist and testedAgainst names nothing."
  drift=$((drift + 1))
else
  released_drift=0
  for mine in "$MINE"/*.json; do
    name=$(basename "$mine")
    if ! (cd "$SRC" && git cat-file -e "$tag:tests/golden/$name" 2>/dev/null); then
      echo "  DRIFTED       release $tag has no $name"
      echo "                These files include a shape that release never produced, so"
      echo "                testedAgainst names the wrong one."
      released_drift=$((released_drift + 1))
      continue
    fi
    if ! (cd "$SRC" && git show "$tag:tests/golden/$name") | diff -q - "$mine" >/dev/null; then
      echo "  DRIFTED       $name differs from release $tag"
      released_drift=$((released_drift + 1))
    fi
  done
  if [ "$released_drift" -eq 0 ]; then
    echo "  same          release ($tag produces these golden files)"
    checked=$((checked + 1))
  else
    echo "                testedAgainst says $mine_version, and $released_drift file(s) here do not"
    echo "                match that release. Either these came from an unreleased tree, or"
    echo "                testedAgainst is behind. The app tells a parent which nestwatch it"
    echo "                was built against, so this is a claim it makes on screen."
    drift=$((drift + released_drift))
  fi
fi

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
# Said before the verdict, so it is read whichever way the verdict goes. A reader who sees
# "nothing drifted" and does not know a file was skipped has been told half the answer.
if [ "$unpublished" -ne 0 ]; then
  echo "$unpublished golden(s) are uncommitted on that side and were not counted:"
  echo "either absent from every commit, or edited on top of a pushed copy that still"
  echo "matches these. Nothing to do until they are pushed. Vendoring one now copies a"
  echo "shape no released nestwatch sends -- the mistake this script warns about above."
  echo
fi
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
