#!/usr/bin/env bash
# Does any resolved package bypass `dart:io`'s HttpClient?
#
# `HttpOverrides.global` is what pins every request in this process. A package that opens
# its own socket, or routes through `cupertino_http` / `cronet_http`, hands its traffic to
# a stack the override never sees -- and it would do so silently, on a phone, in the half
# of the app a parent is not watching.
#
# ## Why this is a script and not a line in the README
#
# It was a line in the README, and the line did not work. It grepped for `SecureSocket`,
# which matches nothing in this pub-cache and nothing in this repo -- so it had never once
# produced a hit, and a clean result was indistinguishable from a broken pattern. It was
# written before any package was checked and never confirmed against a known positive.
#
# So this refuses to report a clean tree until it has proved it can read one: the control
# below greps for something every Dart package contains, and a zero there fails the run.
set -uo pipefail
cd "$(dirname "$0")/.."

# Both overridable so this script can be pointed at a planted tree and shown to fail.
# An audit nobody has watched fail is the state the previous one was in for months.
CACHE="${PUB_CACHE_LIB:-$HOME/.pub-cache/hosted/pub.dev}"
LOCKFILE="${PUBSPEC_LOCK:-pubspec.lock}"

# Anything that reaches the network without going through the HttpClient factory.
# Overridable for the same reason CACHE and LOCKFILE are: so the detector check below can
# be handed a broken pattern and watched to fire.
SUSPECT="${SUSPECT_PATTERN:-cupertino_http|cronet_http|SecureSocket|RawSocket|RawSecureSocket|Socket\.connect|HttpOverrides}"

# Packages that match and are known not to matter, each with the reason it does not.
# Listed rather than filtered out by pattern, because a silent allowlist is how an audit
# stops auditing. An entry that stops matching is reported too -- see STALE below.
declare -a ALLOW_NAME=(dbus)
declare -a ALLOW_WHY=(
  "Unix domain sockets for Linux D-Bus, reached only by flutter_secure_storage's Linux implementation; not compiled into an Android or iOS build"
)

# The packages that actually SHIP, computed rather than assumed.
#
# `pubspec.lock` records every resolved package and cannot say which of them reach a
# release build: a transitive of a dev dependency is marked `transitive`, exactly like a
# transitive of a real one. Auditing the lock therefore flags things that are never
# compiled into the app — `integration_test` pulls in `webdriver`, which pulls in
# `sync_http`, which opens raw sockets and is a test driver.
#
# The first answer to that was going to be another allowlist entry, which is how an audit
# quietly narrows until it checks nothing. `pub deps --json` carries the actual edges, so
# the shipped set is a closure over root dependencies MINUS root devDependencies. Dev-only
# packages then fall out by construction, and the allowlist is left holding only things
# that genuinely ship.
#
# PUB_DEPS_JSON exists so the failure modes below can be driven from a planted graph —
# the same code path, not a parallel one.
resolved=$(mktemp)
trap 'rm -f "$resolved"' EXIT

if [ -n "${PUB_DEPS_JSON:-}" ]; then
  deps_json=$(cat "$PUB_DEPS_JSON")
else
  deps_json=$(flutter pub deps --json 2>/dev/null)
fi

if [ -z "$deps_json" ]; then
  echo "Could not read the dependency graph (flutter pub deps --json)."
  echo
  echo "  Nothing was scanned. That is not the same as nothing being wrong."
  exit 2
fi

printf '%s' "$deps_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pkgs = {p["name"]: p for p in d["packages"]}
root = pkgs.get(d.get("root"), {})
shipped, queue = set(), [
    n for n in root.get("dependencies", [])
    if n not in set(root.get("devDependencies", []))
]
while queue:
    name = queue.pop()
    if name in shipped:
        continue
    shipped.add(name)
    queue.extend(pkgs.get(name, {}).get("dependencies", []))
for name in sorted(shipped):
    p = pkgs.get(name, {})
    if p.get("source") == "hosted":
        sys.stdout.write("%s\t%s-%s\n" % (name, name, p["version"]))
' > "$resolved"

scanned=0
missing=0
control=0
# A file rather than arrays: bash 3.2 under `set -u` errors on an empty array reference,
# and an empty hit list is the ordinary case. check_findings.sh reaches the same shape for
# the same reason.
hits=$(mktemp)
trap 'rm -f "$resolved" "$hits"' EXIT

# The detector check, which is a different question from the control below.
#
# The control proves the grep can READ a tree. It cannot prove `$SUSPECT` can MATCH one:
# the two are different patterns, and only the second is the claim this audit makes. A
# malformed `$SUSPECT` -- one stray `[` while adding a term -- makes grep exit 2 and write
# to the stderr this script discards, so `found` is empty and every package reads as
# clean, while the control still passes and the run still prints "so the grep can see".
# Demonstrated on 2026-08-31 against a planted known positive: the well-formed pattern
# found it, the malformed one returned nothing, and the control passed for both.
#
# So each alternative in `$SUSPECT` is asserted against a planted positive before the
# pub-cache is read at all. Non-vacuity then rests on those plants rather than on whatever
# the cache happens to contain today -- a guard whose non-vacuity depends on the tree it
# guards is one `pub upgrade` away from testing nothing. (The lesson is nestwatch#O79's,
# reached there on the same class of defect; this is that lesson applied here.)
#
# The positives go down a pipe rather than into a temp directory. The check only asks
# match-or-not, and `-r`/`-l` exist to say *which file* matched -- an answer nothing here
# reads. Files would buy a second mktemp, a second thing in the trap, and a write and a
# delete per term, for nothing.
#
# The literal is the alternative with its backslashes stripped, so `Socket\.connect`
# plants `Socket.connect`. An alternative with richer regex syntax would not round-trip
# and would fail this check -- loudly, which is the direction to fail in.
#
# What this does NOT prove, stated because "all 7 terms" reads stronger than it is: that a
# term names a real bypass API. A term is checked against a positive built from itself, so
# a plausible-looking typo passes -- `SocketsButTypoed$$` was tried on 2026-08-31 and did.
# This closes the pattern going blind, not the list being wrong. Nothing here can close
# the second; only knowing the platform can.
detector_ok=1
i=0
# `<<<` rather than a heredoc wrapping a command substitution: check_findings.sh already
# feeds a while-read loop this way, and one idiom for one job is worth more than a
# second way of spelling it.
while IFS= read -r alt; do
  [ -n "$alt" ] || continue
  i=$((i + 1))
  # A here-string, not a pipe: `grep -q` exits at the first match and the writer then
  # takes a broken pipe, which bash reports. The plant is one short line either way.
  #
  # grep's own stderr is deliberately NOT discarded here. When the pattern is malformed it
  # says which way ("brackets ([ ]) not balanced"), and that names the defect that
  # "DETECTOR FAILED" can only point at.
  if ! grep -qE "$SUSPECT" <<< "planted $(printf '%s' "$alt" | tr -d '\\')"; then
    echo "  DETECTOR FAILED — SUSPECT does not match a planted \`$alt\`."
    detector_ok=0
  fi
done <<< "$(printf '%s' "$SUSPECT" | tr '|' '\n')"
if [ "$detector_ok" -eq 0 ]; then
  echo
  echo "  The pattern cannot find what it is looking for, so a clean tree below would"
  echo "  mean nothing. Fix SUSPECT before trusting any result from this run."
  exit 2
fi
echo "Detector: SUSPECT matched a planted positive for all $i of its terms."

while IFS=$'\t' read -r name slug; do
  [ -n "$name" ] || continue
  lib="$CACHE/$slug/lib"
  if [ ! -d "$lib" ]; then
    missing=$((missing + 1))
    continue
  fi
  scanned=$((scanned + 1))
  # The control: every Dart package's lib/ contains at least one of these. If this stops
  # matching, the grep is not reading the tree and no clean result below means anything.
  grep -rqE 'import|class|void|final' "$lib" 2>/dev/null && control=$((control + 1))
  found=$(grep -rlE "$SUSPECT" "$lib" 2>/dev/null | head -3)
  if [ -n "$found" ]; then
    printf '%s\t%s\n' "$name" "$(echo "$found" | sed "s|$CACHE/||" | tr '\n' ' ')" >> "$hits"
  fi
done < "$resolved"

echo "Scanned $scanned package lib/ trees ($missing resolved but not unpacked, so unchecked)."

if [ "$control" -eq 0 ]; then
  echo
  echo "  CONTROL FAILED — the grep matched nothing in any package, including patterns"
  echo "  that must be present. It is not reading the tree. No result below is evidence."
  exit 2
fi
echo "Control: a must-match pattern hit $control of $scanned, so the grep can see."
echo

status=0
while IFS=$'\t' read -r name files; do
  [ -n "$name" ] || continue
  why=""
  for j in "${!ALLOW_NAME[@]}"; do
    [ "${ALLOW_NAME[$j]}" = "$name" ] && why="${ALLOW_WHY[$j]}"
  done
  if [ -n "$why" ]; then
    echo "  known    $name — $why"
  else
    echo "  BYPASS   $name — $files"
    echo "           This package can reach the network without HttpOverrides. Either"
    echo "           show it cannot, or drop it: an unpinned request is the whole risk."
    status=1
  fi
done < "$hits"

# An allowlist entry that no longer matches is an entry nobody has re-justified. Say so
# rather than carrying it forever.
for j in "${!ALLOW_NAME[@]}"; do
  grep -q "^${ALLOW_NAME[$j]}	" "$hits" 2>/dev/null ||
    echo "  STALE    ${ALLOW_NAME[$j]} is allowlisted but no longer matches — remove the entry."
done

echo
if [ "$status" -eq 0 ]; then
  echo "Nothing bypasses HttpClient. Re-run this on every \`pub add\`."
else
  echo "Something bypasses HttpClient. The one dependency rule is broken."
fi
exit "$status"
