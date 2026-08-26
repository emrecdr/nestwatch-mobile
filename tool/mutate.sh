#!/usr/bin/env bash
# Mutation audit: break one behaviour at a time, and see whether `flutter test` notices.
#
# A green suite says nothing about whether it would go red. Each mutation below is a real
# defect this codebase argues about somewhere in its comments; a SURVIVED line means the
# argument is not defended by a test.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/Users/emrec/development/flutter/bin:$PATH"

BACKUP=$(mktemp -d)
cp -R lib "$BACKUP/lib"
restore() { rm -rf lib; cp -R "$BACKUP/lib" lib; }
trap 'restore; rm -rf "$BACKUP"' EXIT

killed=0; survived=0

mutate() {
  local name="$1" file="$2" from="$3" to="$4"
  restore
  python3 - "$file" "$from" "$to" <<'PY'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if frm not in s:
    print("ANCHOR-MISSING", file=sys.stderr); sys.exit(2)
open(path, 'w').write(s.replace(frm, to, 1))
PY
  if [ $? -ne 0 ]; then printf '  %-52s ANCHOR MISSING\n' "$name"; return; fi

  # A mutation that lands in a comment always survives and looks exactly like a coverage
  # gap. This file is comment-dense, so any anchor resembling prose will hit the prose
  # first -- which produced two false gaps before this check existed. Strip comments and
  # blank lines from both versions; if they are identical, only documentation changed.
  if python3 - "$file" "$BACKUP/$file" <<'PY'
import sys
def code(path):
    # Only whole-line comments are stripped. Stripping a trailing `//` would also
    # gut every line containing a URL -- `https://` reads as a comment start to a
    # naive matcher, which made this guard report a real mutation as a no-op.
    return '\n'.join(
        stripped
        for line in open(path)
        for stripped in [line.strip()]
        if stripped and not stripped.startswith('//')
    )
sys.exit(0 if code(sys.argv[1]) == code(sys.argv[2]) else 1)
PY
  then printf '  %-52s NO-OP (hit a comment)\n' "$name"; return; fi
  if flutter test >/dev/null 2>&1; then
    printf '  %-52s SURVIVED\n' "$name"; survived=$((survived+1))
  else
    printf '  %-52s killed\n' "$name"; killed=$((killed+1))
  fi
}

echo "Mutation audit — does 'flutter test' defend what the comments claim?"
echo

mutate "pin: comparison always succeeds" \
  lib/src/pinning/fingerprint.dart \
  '    if (other.length != bytes.length) return false;' \
  '    if (other.length != bytes.length) return true;'

mutate "pin: prefix match is enough" \
  lib/src/pinning/fingerprint.dart \
  '    var diff = 0;' \
  '    if (bytes.length > 4) return true;
    var diff = 0;'

mutate "QR: a damaged #fp= downgrades to TOFU silently" \
  lib/src/pairing/pair_invite.dart \
  '        throw PairInviteFormatException(' \
  '        if (1 > 0) return null;
        throw PairInviteFormatException('

mutate "QR: a missing port becomes https 443" \
  lib/src/pairing/pair_invite.dart \
  '      port: uri.hasPort ? uri.port : nestwatchDefaultPort,' \
  '      port: uri.port,'

mutate "QR: http:// is accepted" \
  lib/src/pairing/pair_invite.dart \
  "    if (uri.scheme != 'https') {" \
  "    if (uri.scheme != 'https' && uri.scheme != 'http') {"

mutate "screenshot: ?tier= dropped (PLAN trap 4)" \
  lib/src/api/nestwatch_api.dart \
  ".getUrl(Uri.parse('https://\$authority/api/screenshot?tier=preview'))" \
  ".getUrl(Uri.parse('https://\$authority/api/screenshot'))"

mutate "cookie: toString leaks the session token" \
  lib/src/api/session_cookie.dart \
  "  String toString() => 'SessionCookie(\${value.length} chars, redacted)';" \
  "  String toString() => 'SessionCookie(\$value)';"

mutate "poll: seen-set accumulates instead of pruning" \
  lib/src/background/seen_requests.dart \
  '  return (fresh: pending.difference(alreadySeen), next: pending);' \
  '  return (fresh: pending.difference(alreadySeen), next: pending.union(alreadySeen));'

mutate "poll: every round re-announces" \
  lib/src/background/seen_requests.dart \
  '  final pending = pendingIds.toSet();' \
  '  final pending = pendingIds.toSet();
  alreadySeen = {};'

mutate "mismatch: an ancient cert reads as a reinstall" \
  lib/src/pinning/pin_mismatch_message.dart \
  '  return age <= reinstallPlausibleWindow' \
  '  return age <= const Duration(days: 3650)'

mutate "usage: a missing heartbeat reads as healthy" \
  lib/src/api/models.dart \
  '    if (age == null) return true;' \
  '    if (age == null) return false;'

mutate "watch: session limit exceeds the daily budget" \
  lib/src/background/watch_now.dart \
  'const Duration watchSessionLimit = Duration(minutes: 30);' \
  'const Duration watchSessionLimit = Duration(hours: 8);'

mutate "provenance: an unknown stored value reads as verified" \
  lib/src/pairing/server_identity.dart \
  "      orElse: () => PinProvenance.trustedOnFirstUse," \
  "      orElse: () => PinProvenance.verifiedFromQrCode,"

mutate "rejection: any authority's answer will do" \
  lib/src/pinning/pinned_http_overrides.dart \
  "  PinRejection? rejectionFor(String authority) => _rejections[authority];" \
  "  PinRejection? rejectionFor(String authority) =>
      _rejections[authority] ?? (_rejections.isEmpty ? null : _rejections.values.last);"

mutate "session: a 401 from /api reads as an unexpected answer" \
  lib/src/api/nestwatch_api.dart \
  "        NestwatchFailure.sessionExpired,
        'That sign-in expired.'," \
  "        NestwatchFailure.unexpectedResponse,
        'That sign-in expired.',"

mutate "cookie: a cleared session is not noticed" \
  lib/src/api/session_cookie.dart \
  "  static bool clearsSession(HttpClientResponse response) => response.cookies" \
  "  static bool clearsSession(HttpClientResponse response) => false || response.cookies
      .where((_) => false)"

mutate "cookie: any cookie name is taken as the session" \
  lib/src/api/session_cookie.dart \
  "      if (cookie.name != name) continue;" \
  "      if (false) continue;"

mutate "token: normalisation stops uppercasing" \
  lib/src/pairing/pair_invite.dart \
  "    .toUpperCase();" \
  "    .toLowerCase();"

mutate "poll: notify before persisting (re-announces after a crash)" \
  lib/src/background/poll_logic.dart \
  "  await store.save(diff.next);" \
  "  await Future<void>.delayed(Duration.zero);"

mutate "login: posts a form instead of JSON" \
  lib/src/api/nestwatch_api.dart \
  "        request.headers.contentType = ContentType.json;" \
  "        request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');"

mutate "redemption: follows the 302 into the dashboard" \
  lib/src/api/nestwatch_api.dart \
  "    await _send('GET', '/p/\$token', followRedirects: false);" \
  "    await _send('GET', '/p/\$token');"

mutate "reuse: close() leaves the pool alive across a pin change" \
  lib/src/api/nestwatch_api.dart \
  "  void close() {
    _http?.close(force: true);
    _http = null;
  }" \
  "  void close() {}"

echo
echo "killed=$killed survived=$survived"
