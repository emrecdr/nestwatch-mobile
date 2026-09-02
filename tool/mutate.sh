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
# **Do not edit anything under `lib/` while this is running.**
#
# `restore` replaces the whole tree, not the one file just mutated — which is what makes it
# safe against a mutation that lands somewhere unexpected, and what makes an edit made
# mid-run vanish without a word. It happened on 2026-09-02: a one-line change to
# `time_requests_screen.dart`, a file this script never mutates, was gone by the next
# command, because the snapshot predated it. Nothing warns; the file simply reverts.
#
# `test/`, `tool/` and `docs/` are untouched and safe to edit — except this file itself,
# which bash reads incrementally as it runs.
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

# The state this app shipped in until 2026-09-02, restored on purpose.
#
# Not an inversion, and the header above is right that those are usually weaker — but
# this one is not hypothetical. `_resolveTimeRequest` read the status and threw the body
# away with `final (response, _)`, so `curfew_note` arrived on every approve and was
# never read. What this defends is that the *reading* is load-bearing, and the honest way
# to state that is to put the defect back.
mutate "approve: the curfew note is received and dropped again" \
  lib/src/api/nestwatch_api.dart \
  "      curfewNote: _stringOrNull(body, 'curfew_note')," \
  "      curfewNote: null,"

# An inversion, and it swaps the two failures for each other: the lapsed session stops
# signing out, and the PC too old to have the endpoint starts. That is precisely the bug
# this guard was added for, so a surviving line here means both directions are unguarded.
mutate "events: the wrong permanent failure signs the parent out" \
  lib/src/api/server_events.dart \
  '          if (error.failure == NestwatchFailure.sessionExpired) {' \
  '          if (error.failure != NestwatchFailure.sessionExpired) {'

# The note reaches `answerReport` and is dropped there instead. A parent answering from
# a lock screen gets silence, which is the surface where silence costs most: the
# notification is already gone, so there is nothing left on screen to carry the caveat.
mutate "notification: a grant bedtime will swallow reports nothing" \
  lib/src/background/notification_actions.dart \
  '  if (note != null) {' \
  '  if (note == null && note != null) {'

# The refusals card appears on every quiet evening instead of the rare loud one. nestwatch's
# own argument for hiding it is that "a card that reads '0, 0, 0' every evening is a card
# that stops being read, and this one has to still be noticeable on the evening it is not
# zero" — so showing it always destroys the property it exists for.
mutate "refusals: a quiet day is reported as a refusal" \
  lib/src/api/models.dart \
  '  bool get any => total > 0;' \
  '  bool get any => total >= 0;'

# The client re-adds the three counts rather than taking the total that PC sent. Identical
# today, and wrong the day a fourth kind of refusal is counted and only the total moves —
# which is exactly why nestwatch sends the sum beside the parts.
mutate "refusals: the total is re-derived instead of taken as sent" \
  lib/src/api/models.dart \
  "      total: (total as num?)?.toInt() ?? 0," \
  "      total: at('clock_changes') + at('day_resets') + at('shutdown_cancels'),"

# A zero count grows a sentence saying zero, which is the thing the section's own rule
# forbids: it appears only when something happened, so a line reading "0 clock changes
# ignored" answers a question nobody asked.
mutate "refusals: a zero count still gets a line" \
  lib/src/ui/refusal_lines.dart \
  '  if (refused.clockChanges > 0)' \
  '  if (refused.clockChanges >= 0)'

# Singular and plural collapse. Reads as "1 clock changes ignored" on the day it fires,
# which is the day the card is being read most carefully.
mutate "refusals: the count and its noun stop agreeing" \
  lib/src/ui/refusal_lines.dart \
  'String _plural(int n, String one, String many) => n == 1 ? one : many;' \
  'String _plural(int n, String one, String many) => many;'

# The spoken label stops saying when the frame is from, which is the half of the old defect
# that mattered: a screen reader gets a picture with no age at all, on the one screen whose
# content outlives its last rebuild.
mutate "screenshot: the spoken label drops the time the frame was taken" \
  lib/src/ui/frame_label.dart \
  "    : 'A picture of the screen on that PC, taken at \${frameClock(frameAt)}.';" \
  "    : 'A picture of the screen on that PC.';"

# The clock loses its padding, so 09:05:03 becomes 9:5:3 -- read aloud as "nine five three"
# rather than a time, and shown that way to everyone else too.
mutate "screenshot: the clock stops zero-padding" \
  lib/src/ui/frame_label.dart \
  "    '\${at.hour.toString().padLeft(2, '0')}:'" \
  "    '\${at.hour.toString()}:'"

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

# The event stream. Dispatch is gated on the data buffer rather than on having seen an
# `event:` line, and that gate is what keeps axum's keep-alive — the literal bytes ":\n\n"
# every 15 seconds — from registering as news and turning a quiet house into a refetch
# loop. The second is the framing space, whose loss would make every tag unrecognisable.
mutate "events: a keep-alive counts as news" \
  lib/src/api/server_events.dart \
  "      if (hasData) yield name.isEmpty ? 'message' : name;" \
  "      yield name.isEmpty ? 'message' : name;"

mutate "events: the framing space is kept as part of the tag" \
  lib/src/api/server_events.dart \
  "    if (value.startsWith(' ')) value = value.substring(1);" \
  "    // framing space kept"

# Answering from the notification. Both invert a decision rather than delete a line: the
# first makes a failed answer look like a granted one, which is the exact silence that
# makes a lock-screen button risky; the second turns an ordinary race into a complaint.
mutate "notification: a failed answer says nothing" \
  lib/src/background/notification_actions.dart \
  "  ActionOutcome.failed =>" \
  "  ActionOutcome.failed => null, // silenced\n  ActionOutcome.values =>"

# Re-anchored 2026-09-02: the line it named became a block when `approveTimeRequest` began
# returning a `Decision` instead of a bool. The audit reported ANCHOR MISSING rather than a
# pass, which is the whole reason that third outcome exists — a mutation that cannot be
# applied has proved nothing, and a run that called it `killed` would have been lying.
mutate "notification: an already-resolved race reads as a grant" \
  lib/src/background/notification_actions.dart \
  "    if (!decision.acted) {" \
  "    if (decision.acted) {"

# Whereabouts. Collapsing the offline case into the elsewhere case would tell a parent
# with no network at all that they are on the wrong one.
mutate "whereabouts: no network reads as a different network" \
  lib/src/api/reachability.dart \
  "  if (usable.isEmpty) return Whereabouts.offline;" \
  "  if (usable.isEmpty) return Whereabouts.looksElsewhere;"

# The two defects deep validation found in this feature, held so they cannot return.
mutate "notification: a body tap counts as an answer" \
  lib/src/background/notification_actions.dart \
  "    type == NotificationResponseType.selectedNotificationAction;" \
  "    type != NotificationResponseType.notificationDismissed;"

mutate "background session: a live app's overrides are replaced" \
  lib/src/background/background_session.dart \
  "  if (HttpOverrides.current is! PinnedHttpOverrides) {
    HttpOverrides.global = PinnedHttpOverrides(pin: identity.fingerprint);
  }" \
  "  HttpOverrides.global = PinnedHttpOverrides(pin: identity.fingerprint);"

mutate "notification: a failed answer is never re-asked" \
  lib/src/background/notification_actions.dart \
  "    await forgetSeen(requestId, seen);" \
  "    // not forgotten"

# The three defects a reader from outside this repo found, and the tests here had agreed
# with the code about. Each inverts the decision that was wrong.
mutate "expiry: the day after lapsing reads as expiring again" \
  lib/src/pinning/certificate_expiry.dart \
  "    final life = remaining.isNegative" \
  "    final life = remaining.inDays < 0"

# Anchored on the inner comparison rather than the whole clause, because the whole clause
# is what `dart format` split across two lines -- a needle spanning a syntactic boundary,
# defeated by the formatter, which is nestwatch#O79's class exactly. This one asserts its
# needle is PRESENT, so it failed closed and said ANCHOR MISSING instead of quietly
# counting as a pass. The shorter needle cannot be broken by reflow: it has no line break
# to be moved to. Mutating it to `false` disables the same decision -- the expiring-soon
# branch stops producing a warning -- with less text to go stale.
mutate "expiry: the last week loses its strip again" \
  lib/src/pinning/certificate_expiry.dart \
  "remaining.inDays <= strippedWithinDays" \
  "false"

mutate "unpair: the announced-request identifiers survive" \
  lib/src/pairing/pairing_controller.dart \
  "    await _forgetAnnounced();" \
  "    // not forgotten"

echo
echo "killed=$killed survived=$survived anchors-missing=$broken"

# The exit status has to mean something, and it did not: this script reported survivors
# and exited 0, so nothing could gate on it. A surviving mutant is an undefended claim; a
# missing anchor is a claim nobody even attempted. Both are failures of the audit.
# Both are failures, and they are not the same failure, so they do not share a status.
#
#   1  a mutation SURVIVED — a claim the tests do not defend. The code is the problem.
#   2  an anchor is MISSING — the mutation never ran. The harness is the problem, and
#      nothing was learned about the code either way.
#
# This is the same 0/1/2 the other checkers here use: 2 means "could not check", which is
# exactly what a stale anchor is. Both are non-zero, so CI reds either way; the difference
# is for whoever reads the status and has to decide which thing to go fix.
if [ "$survived" -ne 0 ]; then
  echo
  echo "$survived mutation(s) SURVIVED — a comment argues for something no test defends."
  [ "$broken" -ne 0 ] &&
    echo "$broken anchor(s) MISSING as well — those did not run. Not the same as passing."
  exit 1
fi
if [ "$broken" -ne 0 ]; then
  echo
  echo "$broken anchor(s) MISSING — those mutations did not run. Not the same as passing."
  exit 2
fi
