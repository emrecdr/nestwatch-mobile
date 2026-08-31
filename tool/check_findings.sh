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

echo "Checking references between $MINE and $THEIRS"
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
