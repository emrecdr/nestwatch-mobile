#!/usr/bin/env bash
# Mutation audit: break one behaviour at a time, and see whether `flutter test` notices.
#
# A green suite says nothing about whether it would go red. Each mutation below is a real
# defect this codebase argues about somewhere in its comments; a SURVIVED line means the
# argument is not defended by a test.
#
# ---------------------------------------------------------------------------------
# Write mutations that INVERT A DECISION, not ones that delete a line.
# ---------------------------------------------------------------------------------
#
# Deleting is what anyone reaches for first, and it is the weaker kind. Removing a call
# proves only that the code does what the code does: some test somewhere observes the
# missing effect, and it would have failed for a typo just as readily. Inverting the
# decision asks the question that matters — is the *choice* defended, or merely
# implemented?
#
# The poll-ordering entry is the worked example. `pollOnce` announces before it persists,
# and the reason is load-bearing: persisting first marks a request seen before the parent
# is told, so a failing notify loses it permanently and silently. The first version of
# that mutation deleted the save. It was killed, but by a test for something else
# entirely — nothing checked the ordering. Replacing it with a mutation that puts the
# save back *in front* of the notify is what made the audit defend the argument rather
# than restate the implementation.
#
# Three ways a mutation lies about coverage, all of which have happened here:
#
#   * it lands in a comment      -> guarded below; reported as NO-OP (hit a comment)
#   * it is a no-op in disguise  -> `x != 'a' && x != 'a'` is the same condition twice
#   * the fixture cannot reach the condition it claims to test -- a stub answering 200
#     can never disprove "we do not follow redirects"
#
# The first two are detectable mechanically. The third is not, and is the reason a
# mutation surviving deserves reading before it is believed.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/Users/emrec/development/flutter/bin:$PATH"

BACKUP=$(mktemp -d)
cp -R lib "$BACKUP/lib"
restore() { rm -rf lib; cp -R "$BACKUP/lib" lib; }
trap 'restore; rm -rf "$BACKUP"' EXIT

killed=0; survived=0; broken=0

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
  # Counted, not just printed. The header above tells the story of an anchor that
  # stopped matching after a refactor moved a line: the total went 24 to 23 and the run
  # still said survived=0. That lesson was written into this comment and not into the
  # arithmetic, so the same run would still have exited 0 and passed a gate.
  #
  # `check_golden.sh` states the rule this file needed: a thing that cannot be found must
  # read as an error, never as agreement.
  if [ $? -ne 0 ]; then
    printf '  %-52s ANCHOR MISSING\n' "$name"
    broken=$((broken + 1))
    return
  fi

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
  "    final query = onTimer ? '?tier=preview&live=1' : '?tier=preview';" \
  "    final query = onTimer ? '?live=1' : '';"

mutate "screenshot: timer frames omit live=1 (audit-log eviction)" \
  lib/src/api/nestwatch_api.dart \
  "    final query = onTimer ? '?tier=preview&live=1' : '?tier=preview';" \
  "    final query = '?tier=preview';"

mutate "screenshot: the served tier is not reported" \
  lib/src/api/nestwatch_api.dart \
  "        servedTier: served," \
  "        servedTier: null,"

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

# The UI layer had no mutation at all until the screens were deduped — no widget tests
# either, so the rule deciding whether a parent can get back in was defended by nothing.
# The startup ordering: the pin is installed before the first frame, and the network
# probe is not. Both halves were one awaited method until the second was measured
# blocking the first frame for a handshake.
mutate "startup: the pin is not applied before the first frame" \
  lib/src/pairing/pairing_controller.dart \
  "    _overrides.trust(stored.fingerprint);" \
  "    if (stored.provenance == PinProvenance.trustedOnFirstUse) {
      _overrides.trust(stored.fingerprint);
    }"

mutate "startup: restoreSession overwrites what the parent is looking at" \
  lib/src/pairing/pairing_controller.dart \
  "    if (_state is! PairingBusy) return;" \
  "    if (_state is PairingBusy) {}"

# PLAN §5's "stop both when not visible" — argued for at length in poller.dart and
# defended by nothing until the gate moved out of a widget mixin and into Poller.
mutate "poller: an off-screen tab keeps asking that PC" \
  lib/src/ui/poller.dart \
  "    final shouldRun = _wanted && _visible && _foreground;" \
  "    final shouldRun = _wanted && _foreground;"

mutate "poller: a poller runs before it is told it is visible" \
  lib/src/ui/poller.dart \
  "  bool _visible = false;" \
  "  bool _visible = true;"

mutate "screens: a lapsed session is drawn instead of handed up" \
  lib/src/ui/screen_load.dart \
  "    if (e.failure == NestwatchFailure.sessionExpired) return HandedBack(e);" \
  "    if (e.failure != NestwatchFailure.sessionExpired) return HandedBack(e);"

mutate "LAN: a 403 is not recognised as require_lan_peer" \
  lib/src/api/nestwatch_api.dart \
  "    if (response.statusCode == HttpStatus.forbidden) {" \
  "    if (response.statusCode == HttpStatus.notFound) {"

mutate "cookie: a cleared session reads as an ordinary one" \
  lib/src/api/session_cookie.dart \
  "        return (cleared: true, issued: null);" \
  "        return (cleared: false, issued: null);"

mutate "cookie: any cookie name is taken as the session" \
  lib/src/api/session_cookie.dart \
  "      if (cookie.name != name) continue;" \
  "      if (false) continue;"

mutate "token: normalisation stops uppercasing" \
  lib/src/pairing/pair_invite.dart \
  "    .toUpperCase();" \
  "    .toLowerCase();"

mutate "poll: persist before announcing (loses a request if notify throws)" \
  lib/src/background/poll_logic.dart \
  "  if (diff.fresh.isNotEmpty) {
    await notify(pending.where((r) => diff.fresh.contains(r.id)).toList());
  }

  // Reached only once the announcement succeeded. A throw above leaves the store
  // untouched, which is what makes the next round a retry rather than a loss.
  await store.save(diff.next);" \
  "  await store.save(diff.next);

  if (diff.fresh.isNotEmpty) {
    await notify(pending.where((r) => diff.fresh.contains(r.id)).toList());
  }"

mutate "login: posts a form instead of JSON" \
  lib/src/api/nestwatch_api.dart \
  "      request.headers.contentType = ContentType.json;" \
  "      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');"

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

# PLAN §5's version check. Both mutations invert a decision rather than delete a line: the
# first folds "could not tell" into agreement, which is the exact failure this three-valued
# verdict exists to prevent, and the second stops the comparison distinguishing direction.
mutate "version: unreadable folded into agreement" \
  lib/src/api/server_contract.dart \
  "    if (theirs == null || ours == null) {
      return ContractCheck._(ContractAgreement.unreadable, reported);
    }" \
  "    if (theirs == null || ours == null) {
      return ContractCheck._(ContractAgreement.agreed, reported);
    }"

mutate "version: an older PC reported as a newer one" \
  lib/src/api/server_contract.dart \
  "      theirRank < ourRank
          ? ContractAgreement.serverOlder
          : ContractAgreement.serverNewer," \
  "      theirRank > ourRank
          ? ContractAgreement.serverOlder
          : ContractAgreement.serverNewer,"

# The expiry warning. The first stops the end date ever being recorded, which is the
# silent version of this feature not existing; the second removes the expired branch, so a
# lapsed certificate reads as merely close to lapsing.
mutate "expiry: the accepted end date is never recorded" \
  lib/src/pinning/pinned_http_overrides.dart \
  "      _acceptedNotAfter = cert.endValidity;" \
  "      _acceptedNotAfter = null;"

mutate "expiry: an expired certificate reads as merely expiring" \
  lib/src/pinning/certificate_expiry.dart \
  "      < 0 => CertificateLife.expired," \
  "      < -99999 => CertificateLife.expired,"

echo
echo "killed=$killed survived=$survived anchors-missing=$broken"

# The exit status has to mean something, and it did not: this script reported survivors
# and exited 0, so nothing could gate on it. A surviving mutant is an undefended claim; a
# missing anchor is a claim nobody even attempted. Both are failures of the audit.
if [ "$survived" -ne 0 ] || [ "$broken" -ne 0 ]; then
  echo
  [ "$survived" -ne 0 ] && echo "$survived mutation(s) SURVIVED — a comment argues for something no test defends."
  [ "$broken" -ne 0 ] && echo "$broken anchor(s) MISSING — those mutations did not run. Not the same as passing."
  exit 1
fi
