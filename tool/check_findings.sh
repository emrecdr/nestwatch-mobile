#!/usr/bin/env bash
# Do the cross-repo references in the two findings files still resolve?
#
# `docs/OPEN-FINDINGS.md` here and `docs/OPEN-FINDINGS.md` in nestwatch now cite each other
# — one repo files something the other has to act on, and the entry names its counterpart.
# Prose citations rot, and this one rots in the worst possible direction.
#
# ## The failure this exists to catch
#
# Both files carry the same rule: **when a finding is fixed, delete its entry.** So a
# reference resolving today and missing tomorrow does not mean somebody was careless. It
# means the other side FIXED IT — and for a blocked entry, that is the exact moment it
# stops being blocked and becomes work. M6 says "delete the sed once nestwatch publishes
# the constant"; the way this repo learns that day arrived is the O72 heading vanishing.
#
# So a dangling reference is not an error to tidy away. It is the notification.
#
# Three outcomes, and the third is the point: resolved, dangling, and **could not look** —
# the sibling checkout is not here, so nothing was compared and saying "all fine" would be
# a lie a person would believe.
set -uo pipefail
cd "$(dirname "$0")/.."

MINE="docs/OPEN-FINDINGS.md"
SIBLING="${NESTWATCH_REPO:-../nestwatch}"
THEIRS="$SIBLING/docs/OPEN-FINDINGS.md"

# Repo name -> findings file, so a reference names a repo rather than a path.
resolve_file() {
  case "$1" in
    nestwatch) echo "$THEIRS" ;;
    nestwatch-mobile) echo "$MINE" ;;
    *) echo "" ;;
  esac
}

if [ ! -f "$MINE" ]; then
  echo "No $MINE here. Nothing was checked."
  exit 2
fi

if [ ! -f "$THEIRS" ]; then
  echo "nestwatch's findings file not found at $THEIRS"
  echo
  echo "  Nothing was compared. References across the two repos may be dangling and"
  echo "  this script cannot tell. Set NESTWATCH_REPO to the checkout and run again."
  exit 2
fi

# **Which tree is that, though?**
#
# `NESTWATCH_REPO` defaults to `../nestwatch`, a WORKING TREE that may hold anything: local
# commits, unpushed work, a half-finished afternoon. CI clones the pushed branch instead,
# so the same command answers about two different trees and both answers are true.
#
# `tool/check_golden.sh` has carried that warning since 2026-09-02, when goldens vendored
# out of unpushed work passed locally and failed in CI. This script did not, and the
# asymmetry was filed as `M25` rather than fixed: run against the checkout on 2026-09-04 it
# reported `O10` and `O34` dangling; run against `git archive origin/main` it reported
# everything resolving. Neither run was wrong. Neither run said which tree it had read.
#
# **The direction of the error is the opposite of the golden checker's, and worse.** There,
# a file that exists only on disk produces false DRIFT — loud, and somebody goes and looks.
# Here, an entry that exists only on disk makes a reference RESOLVE: the heading is right
# there, the script says "all fine" and exits 0, and the notification this whole file
# exists to deliver is the thing that goes missing. Silence is the failure mode. So this
# reports on a clean run too, rather than only when it has something to complain about.
#
# Measured 2026-09-08: both trees answered identically, and every condition for them not to
# was present and unreported — the sibling's findings file uncommitted, its HEAD not in
# `origin/main`. Two trees agreeing is luck on a given day, not a property.
#
# Read from the local remote-tracking ref rather than the network, so this still works
# offline. That ref can be stale, so this can call published work local; it cannot stay
# silent about work that is not published, which is the direction that matters.
echo "Checking references between $MINE and $THEIRS"

sibling_sha=$(cd "$SIBLING" && git rev-parse --short HEAD 2>/dev/null)
if [ -z "$sibling_sha" ]; then
  # An extracted archive rather than a checkout — which is how M25 was measured, so it is a
  # real way to run this and not a mistake. There is simply no commit to ask about.
  echo "  that copy is not a git checkout — cannot tell you which commit it is"
elif ! (cd "$SIBLING" && git rev-parse --verify -q origin/main >/dev/null); then
  echo "  that checkout is at $sibling_sha, with no origin/main to compare it to"
elif ! (cd "$SIBLING" && git merge-base --is-ancestor HEAD origin/main 2>/dev/null); then
  echo "  that checkout is at $sibling_sha, which is NOT in its origin/main — you are"
  echo "  reading local work, and CI resolves these against the pushed branch instead."
  echo "  (If origin/main is merely stale, fetch and re-run.)"
else
  echo "  that checkout is at $sibling_sha, which is published"
fi

dirty=$(cd "$SIBLING" && git status --porcelain -- docs/OPEN-FINDINGS.md 2>/dev/null)
if [ -n "$dirty" ]; then
  echo "  and its findings file is uncommitted:"
  echo "$dirty" | sed 's/^/        /'
  echo "  That file is in no commit, so CI reads a different one. An entry present only"
  echo "  here resolves a reference that CI will report dangling, and this script going"
  echo "  quiet is exactly what that looks like from the outside."
fi
echo

dangling=0
checked=0

# Every `repo#ID` reference in either file, deduplicated, with where it was found.
#
# Scoped to the entries — everything after the `## Open` heading — on purpose. Both files
# explain this convention above that line, using real IDs as examples, and a checker that
# read its own documentation would fire a false notification the day one of those examples
# got fixed. The instructions are not a citation.
entry_refs() {
  sed -n '/^## Open/,$p' "$1" |
    grep -ohE '\b(nestwatch|nestwatch-mobile)#[OM][0-9]+' |
    sort -u |
    sed "s|^|$1 |"
}
refs=$(entry_refs "$MINE"; entry_refs "$THEIRS")

if [ -z "$refs" ]; then
  echo "  No cross-repo references in either file."
  echo
  echo "0 references checked. That is a real answer, not a pass — if the two repos have"
  echo "work in common, nothing here is saying so."
  exit 0
fi

while read -r from ref; do
  [ -n "$ref" ] || continue
  repo="${ref%%#*}"
  id="${ref##*#}"
  target=$(resolve_file "$repo")
  checked=$((checked + 1))

  if [ -z "$target" ] || [ ! -f "$target" ]; then
    echo "  UNREADABLE    $ref (cited by $from) — no findings file for repo '$repo'"
    dangling=$((dangling + 1))
  elif grep -qE "^### $id( |·|\`)" "$target"; then
    echo "  resolves      $ref  ($from)"
  else
    echo "  DANGLING      $ref (cited by $from) — no '### $id' in $target"
    echo "                Both files delete an entry when it is FIXED. So this most"
    echo "                likely means the other side did it, and whatever cited it is"
    echo "                now work rather than a wait. Go read that entry."
    dangling=$((dangling + 1))
  fi
done <<< "$refs"

# References within one file, which are the easy ones to get wrong precisely because they
# look too simple to check. Added after a "pairs with M11" was written pointing at the
# connectivity entry when it meant the undo one — caught by a shell loop run by hand, which
# is not a thing anybody will remember to do twice.
#
# Cheap and local: no sibling checkout needed, so this half still runs when the other does
# not. Scoped to entries for the same reason as above.
echo
internal_report=$(mktemp)
for pair in "$MINE M" "$THEIRS O"; do
  set -- $pair
  file="$1"; prefix="$2"
  for id in $(sed -n '/^## Open/,$p' "$file" | grep -ohE "\b$prefix[0-9]+\b" | sort -u); do
    grep -qE "^### $id( |·|\`)" "$file" ||
      echo "  DANGLING      $id — cited inside $file, but no '### $id' in it" >> "$internal_report"
  done
done
internal=$(wc -l < "$internal_report" | tr -d ' ')
if [ "$internal" -eq 0 ]; then
  echo "  all same-file references resolve, both sides"
else
  cat "$internal_report"
  dangling=$((dangling + internal))
fi
rm -f "$internal_report"

echo
# Two different facts, and folding them into one exit code makes CI red on good news.
#
# A **same-file** dangle is unambiguously a mistake in the file being checked: the entry it
# names is right there or it is not, and nothing outside this repository can change that.
#
# A **cross-repo** dangle cannot be told apart from here. Both files delete an entry when
# it is fixed, so the reference most likely dangles because the other side shipped it --
# but a typo in the id looks identical, and so does citing an entry before the other repo
# has pushed. That is the third outcome this repo insists on everywhere else, and it earns
# its own exit code rather than being reported as failure or hidden as success.
#
#   0  everything resolves
#   1  a same-file reference dangles -- a real error, here
#   3  only cross-repo references dangle -- go read them; cannot be decided by this script
if [ "$internal" -gt 0 ]; then
  echo "$internal same-file reference(s) dangling. That is an error in the file itself."
  [ "$dangling" -gt "$internal" ] &&
    echo "$((dangling - internal)) cross-repo one(s) too — see above."
  exit 1
fi
if [ "$dangling" -eq 0 ]; then
  echo "$checked cross-repo reference(s) resolving, and no dangling same-file ones."
  exit 0
fi
echo "$dangling cross-repo reference(s) dangling, and no same-file ones."
echo
echo "  This is not decided here. Either the other side fixed and deleted those entries --"
echo "  which is good news, and makes whatever cited them work rather than a wait -- or the"
echo "  id is wrong, or that repo has not pushed it yet. Go read them."
exit 3
