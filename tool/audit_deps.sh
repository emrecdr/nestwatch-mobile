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
SUSPECT='cupertino_http|cronet_http|SecureSocket|RawSocket|RawSecureSocket|Socket\.connect|HttpOverrides'

# Packages that match and are known not to matter, each with the reason it does not.
# Listed rather than filtered out by pattern, because a silent allowlist is how an audit
# stops auditing. An entry that stops matching is reported too -- see STALE below.
declare -a ALLOW_NAME=(dbus vm_service)
declare -a ALLOW_WHY=(
  "Unix domain sockets for Linux D-Bus, reached only by flutter_secure_storage's Linux implementation; not compiled into an Android build"
  "the VM service protocol, a dev-time transitive of flutter_test; not shipped"
)

# macOS ships bash 3.2, which has no `mapfile` -- a plain read loop over a temp file
# works everywhere, and the other scripts here already assume nothing newer.
resolved=$(mktemp)
trap 'rm -f "$resolved"' EXIT
python3 - > "$resolved" <<'LOCK'
import re
import os
s = open(os.environ.get('PUBSPEC_LOCK', 'pubspec.lock')).read()
for m in re.finditer(r'^  ([a-z_0-9]+):\n(?:.*\n)*?    source: hosted\n    version: "([^"]+)"', s, re.M):
    print(f"{m.group(1)}\t{m.group(1)}-{m.group(2)}")
LOCK

scanned=0
missing=0
control=0
declare -a hits_name=()
declare -a hits_file=()

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
    hits_name+=("$name")
    hits_file+=("$(echo "$found" | sed "s|$CACHE/||" | tr '\n' ' ')")
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
for i in "${!hits_name[@]}"; do
  name="${hits_name[$i]}"
  why=""
  for j in "${!ALLOW_NAME[@]}"; do
    [ "${ALLOW_NAME[$j]}" = "$name" ] && why="${ALLOW_WHY[$j]}"
  done
  if [ -n "$why" ]; then
    echo "  known    $name — $why"
  else
    echo "  BYPASS   $name — ${hits_file[$i]}"
    echo "           This package can reach the network without HttpOverrides. Either"
    echo "           show it cannot, or drop it: an unpinned request is the whole risk."
    status=1
  fi
done

# An allowlist entry that no longer matches is an entry nobody has re-justified. Say so
# rather than carrying it forever.
for j in "${!ALLOW_NAME[@]}"; do
  hit=0
  for n in "${hits_name[@]}"; do [ "$n" = "${ALLOW_NAME[$j]}" ] && hit=1; done
  [ "$hit" -eq 0 ] && echo "  STALE    ${ALLOW_NAME[$j]} is allowlisted but no longer matches — remove the entry."
done

echo
if [ "$status" -eq 0 ]; then
  echo "Nothing bypasses HttpClient. Re-run this on every \`pub add\`."
else
  echo "Something bypasses HttpClient. The one dependency rule is broken."
fi
exit "$status"
