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

echo
if [ "$dangling" -eq 0 ]; then
  echo "$checked reference(s), all resolving."
else
  echo "$dangling of $checked dangling — see above. Most likely good news."
fi
exit "$dangling"
