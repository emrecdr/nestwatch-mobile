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
#
# **And the mirror of that rule: a mutation may only target a file under `lib/`.** The
# snapshot is `lib/` and so is the restore, so a mutation pointed at `android/`, `ios/` or
# a manifest would apply and never be put back — the tree is left broken, silently, and the
# `EXIT` trap would report a clean finish over the top of it.
#
# It comes up more than it sounds, because several tests here read source that is not Dart:
# `flag_secure_test.dart` reads Kotlin, `ios_config_test.dart` reads `Info.plist` and the
# Xcode project, `store_requirements_test.dart` reads the Android manifest. Those checks
# are worth having and none of them can be mutation-audited from here. Prove them the way
# the ones already in this repository were proved — break the file by hand, watch the test
# go red, restore it — and say in the commit that you did.
restore() { rm -rf lib; cp -R "$BACKUP/lib" lib; }
trap 'restore; rm -rf "$BACKUP"' EXIT

killed=0; survived=0; broken=0

mutate() {
  local name="$1" file="$2" from="$3" to="$4"
  restore

  # `ANCHORS_ONLY=1 bash tool/mutate.sh` checks every anchor and runs no tests.
  #
  # Added after a run spent twelve minutes to report two stale anchors, both broken by the
  # same refactor an hour earlier: `store.announced()` became `store.announcedAt()`, and
  # two mutations quoting the old shape silently stopped mutating anything. A stale anchor
  # is the failure this script is *least* able to warn about cheaply, because finding it
  # costs a full audit — so finding it must not cost a full audit.
  #
  # Deliberately not a substitute for the run. A matching anchor says the mutation will
  # apply, and nothing whatever about whether a test would catch it.
  if [ "${ANCHORS_ONLY:-0}" = "1" ]; then
    if python3 -c 'import sys; sys.exit(0 if sys.argv[2] in open(sys.argv[1]).read() else 1)' \
         "$file" "$from"; then
      printf '  %-52s anchor ok\n' "$name"
    else
      printf '  %-52s ANCHOR MISSING\n' "$name"
      broken=$((broken + 1))
      verdicts+=("  ANCHOR MISSING $name")
    fi
    return
  fi

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
    verdicts+=("  ANCHOR MISSING $name")
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
    verdicts+=("  SURVIVED       $name")
  else
    printf '  %-52s killed\n' "$name"; killed=$((killed+1))
  fi
}

# Print the verdict lines LAST as well as inline, so a caller that pipes this through
# `tail` still sees which mutation survived.
#
# Not hypothetical. On 2026-09-04 a run reported `survived=1` through `tail -8`, and the
# name of the survivor had scrolled past -- so identifying it meant re-running four
# mutations by hand. The obvious fix, piping through `grep -E "SURVIVED|killed="`, is worse
# here than it looks: this machine rewrites a bare top-level `grep`, which turned a whole
# audit's output into `error: unknown option '-G'`. A summary the script prints itself
# needs no filter at the call site.
declare -a verdicts=()

summary() {
  # `${verdicts[@]}` on an empty array is an *unbound variable* under `set -u` on bash 3.2,
  # which is what macOS ships -- so the expansion is guarded rather than the caller trusted
  # to only reach it when something was recorded.
  [ "${#verdicts[@]}" -eq 0 ] && return
  echo
  echo "Not clean — the lines that matter, repeated so a truncated view still has them:"
  printf '%s\n' "${verdicts[@]}"
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
# Re-anchored after `Refusals.fromUsage` began reading both keys itself rather than being
# handed the sibling total as an untyped positional. The line moved; the decision did not.
mutate "refusals: the total is re-derived instead of taken as sent" \
  lib/src/api/models.dart \
  "        total: (usage['refused_total'] as num?)?.toInt() ?? 0," \
  "        total: at('clock_changes') + at('day_resets') + at('shutdown_cancels'),"

# A zero count grows a sentence saying zero, which is the thing the section's own rule
# forbids: it appears only when something happened, so a line reading "0 clock changes
# ignored" answers a question nobody asked.
mutate "refusals: a zero count still gets a line" \
  lib/src/ui/refusal_lines.dart \
  '  if (refused.clockChanges > 0)' \
  '  if (refused.clockChanges >= 0)'

# The fourth count, added in nestwatch 0.8.0, is read from a key that is already being read.
# Both fields then carry `shutdown_cancels`, the card names the right number of things and
# gets one of them wrong, and every existing assertion still passes -- `refused_total` is
# taken as sent, so the total stays right while a part is silently a copy of its neighbour.
mutate "refusals: the fourth kind is read from the wrong key" \
  lib/src/api/models.dart \
  "        timeCodesRefused: at('time_codes_refused')," \
  "        timeCodesRefused: at('shutdown_cancels'),"

# Same shape as the clock-changes mutation above, aimed at the line added with 0.8.0. A
# zero grows a sentence saying zero, on the card whose rule is that it only appears when
# something happened.
mutate "refusals: a zero time-code count still gets a line" \
  lib/src/ui/refusal_lines.dart \
  '  if (refused.timeCodesRefused > 0)' \
  '  if (refused.timeCodesRefused >= 0)'

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

# An unknown scope kind is read as permission. Fails OPEN, which is the direction that
# matters: a nestwatch inventing a third kind would be trusted by an app that predates it.
mutate "scope: a kind this build cannot name is accepted anyway" \
  lib/src/api/nestwatch_api.dart \
  "    {'kind': _} => unrecognised," \
  "    {'kind': _} => dashboard,"

# Re-anchored 2026-09-04. The first version of this keyed the exemption on
# `ContractCheck.serverOlder` and **survived** -- no test distinguished a PC merely newer
# from one behind, because the version was a proxy for a fact the server states outright.
# The fix reads the key's presence; this now inverts that, so a pre-0.7.0 PC is refused and
# a lapsed session is accepted -- both directions wrong at once.
mutate "scope: absent and present-and-null swap meanings" \
  lib/src/pairing/pairing_controller.dart \
  '  if (!session.reportsScopes) return null;' \
  '  if (session.reportsScopes) return null;'

# Presence collapses into value, which is the defect the audit found: the two answers
# nestwatch deliberately made distinguishable become one again.
mutate "scope: a missing key reads the same as an explicit null" \
  lib/src/api/nestwatch_api.dart \
  "    reportsScopes: json.containsKey('scope')," \
  "    reportsScopes: json['scope'] != null,"

# The gate stops rejecting anything: every pairing drives the app, including the
# integration one that can only reach two routes.
mutate "scope: an integration pairing is allowed to drive the app" \
  lib/src/pairing/pairing_controller.dart \
  '  if (scope.isDashboard) return null;' \
  '  if (!scope.isDashboard) return null;'

# The 403 body is ignored again, so a scope refusal is reported as a VPN problem -- one
# working tab beside three blaming the network.
mutate "403: the pairing refusal is reported as a network problem" \
  lib/src/api/nestwatch_api.dart \
  '      if (said.isNotEmpty) {' \
  '      if (said.isEmpty) {'

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

# Three of the four causes named there mean "go and look at that PC"; the fourth means
# "find the new address and type it", which is a different errand. Putting the sentence
# back the way it was leaves a parent whose PC moved reading a list that excludes what
# actually happened -- the shape this repository keeps finding.
mutate "whereabouts: the moved-address cause goes unmentioned again" \
  lib/src/api/reachability.dart \
  "        'not running on it — or that its address on this network has changed since '
        'you paired.'," \
  "        'not running on it.',"

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

# --- nestwatch 0.7.0: the absolute session cap ---------------------------------------
#
# 0.7.0 added `SESSION_MAX_DAYS`, a ceiling measured from `first_seen` that activity does
# not move -- so every paired phone loses its session exactly one month after pairing.
# Before it, a polled session slid its own expiry forward and effectively never lapsed,
# which is why folding "lapsed" in with "away from home" and staying silent was survivable.
# These four hold the parts of that fix a comment would otherwise be arguing alone.

# The discrimination inverts: an away-from-home phone raises the alarm four times an hour,
# and a session that has actually ended says nothing. Both directions wrong at once.
mutate "session: a transient failure alarms and a real lapse stays silent" \
  lib/src/background/poll_logic.dart \
  '    if (e.failure == NestwatchFailure.sessionExpired) {' \
  '    if (e.failure != NestwatchFailure.sessionExpired) {'

# The latch stops latching, so a lapse that lasts a week is 672 notifications.
mutate "session: the parent is re-told every fifteen minutes" \
  lib/src/background/sign_in_notice.dart \
  '    if (last != null && _alreadySaid(last, moment)) return;' \
  '    if (false) return;'

# Recorded before announced. A notification that then fails to post is marked as sent,
# permanently, and the background isolate reports success either way -- so the parent is
# never told and nothing anywhere says so.
mutate "session: the notice is recorded as sent before it is sent" \
  lib/src/background/sign_in_notice.dart \
  '    await announce();
    await store.markAnnounced(moment);' \
  '    await store.markAnnounced(moment);
    await announce();'

# Cleared before withdrawn, so a failed withdrawal strands a notice on screen with the
# flag already re-armed and nothing left that knows to remove it.
mutate "session: the notice is re-armed before it is taken down" \
  lib/src/background/sign_in_notice.dart \
  '    await withdraw();
    await store.clear();' \
  '    await store.clear();
    await withdraw();'

# --- nestwatch 0.7.0: what this phone calls itself ------------------------------------

# The id moves into the range `request.id.hashCode` occupies, where a pending request and
# the "sign in again" notice can silently replace one another.
mutate "session: the notice id can collide with a request id" \
  lib/src/background/notifications.dart \
  'const int signInNoticeId = -1;' \
  'const int signInNoticeId = 1;'

# The app stops naming itself, so the *Signed-in devices* card shows a row a parent cannot
# recognise -- next to the button that signs that device out.
mutate "identity: the user agent stops naming this app" \
  lib/src/api/client_identity.dart \
  "    'nestwatch-mobile/\$appVersion (\$operatingSystem)';" \
  "    'Dart/3.12 (dart:io)';"

# The watch service stops on a false answer. Reporting a rejected session as "still signed
# in" leaves a foreground service, and a persistent notification, claiming to watch a PC
# that has signed this phone out.
mutate "watch: a rejected session still reads as signed in" \
  lib/src/background/poll_logic.dart \
  '      return false;' \
  '      return true;'

# The sign-in notice was raised by the poll and lowered by the poll, and by nothing else.
# That loop cannot close: `lower()` is reached only after a request SUCCEEDS, and a request
# cannot succeed while the session is the broken thing. Both mutations below restore a
# version of that: the parent signs in, and is still being told to sign in.
mutate "session: signing in leaves the notice standing" \
  lib/src/pairing/pairing_controller.dart \
  '      await _withdrawSignInNotice();
    } on Object catch (_) {' \
  '      await Future<void>.value();
    } on Object catch (_) {'

# Withdrawing on ANY authenticated answer rather than on a usable one. An integration
# pairing signs in and still cannot read time requests, so the notice -- "this phone can no
# longer tell you when your child asks" -- is still true, and taking it down is a lie told
# to a parent whose phone is about to go on being useless.
mutate "session: a pairing this app cannot drive takes the notice down anyway" \
  lib/src/pairing/pairing_controller.dart \
  '    if (refusal != null) {
      _emit(PairingFailed(refusal));' \
  '    if (refusal != null) {
      await _withdrawSignInNotice();
      _emit(PairingFailed(refusal));'

# "Forget this PC" left the fourth stored item behind, and could leave a notification on
# screen naming a PC this app had just been told to forget.
mutate "unpair: the sign-in notice outlives the pairing" \
  lib/src/pairing/pairing_controller.dart \
  '    await _withdrawSignInNotice();
    _current = null;' \
  '    _current = null;'

# The backwards-clock guard. `elapsed < renotifyAfter` is true of every NEGATIVE duration,
# so without the first half a phone whose clock moved back goes silent for as long as it
# stays behind -- about the one thing it cannot afford to be silent about.
mutate "session: a clock that moved backwards silences the notice" \
  lib/src/background/sign_in_notice.dart \
  '    return !elapsed.isNegative && elapsed < renotifyAfter;' \
  '    return elapsed < renotifyAfter;'

# The interval that turns "told once, ever" back on. A parent who swipes the notice away
# without acting is then never told again, for as long as the lapse lasts.
# Survived once, and the mutation was right -- the TEST was wrong. It advanced its clock by
# `SignInNotice.renotifyAfter`, so a mutated constant moved the clock too and the assertion
# went on passing. A test whose input is derived from the thing under test cannot see it
# change. Same shape as `M26`, one file over. The tests now use literal durations, and a
# separate one pins the constant itself.
mutate "session: the notice is never repeated" \
  lib/src/background/sign_in_notice.dart \
  '  static const Duration renotifyAfter = Duration(days: 1);' \
  '  static const Duration renotifyAfter = Duration(days: 36500);'

# And the other direction: back to nagging. A notice every poll is the fifteen-minute alarm
# `notifications.dart` says "teaches a parent to dismiss it unread".
mutate "session: the notice goes back to every fifteen minutes" \
  lib/src/background/sign_in_notice.dart \
  '  static const Duration renotifyAfter = Duration(days: 1);' \
  '  static const Duration renotifyAfter = Duration.zero;'

# Two isolates poll the same PC against one store with no lock between load and save, so a
# request can be announced twice. The id makes the second one a REPLACEMENT; this flag is
# what stops the replacement buzzing a parent about a request they have already seen.
mutate "notification: a replaced request alerts a second time" \
  lib/src/background/notifications.dart \
  '    onlyAlertOnce: true,
    // Answer without opening anything.' \
  '    onlyAlertOnce: false,
    // Answer without opening anything.'

# The privacy screen listed three stored items when there were four, and promised "Forget
# this PC" deleted all of them. That is a false statement about data handling in the
# document Play requires to be truthful -- and it is the SECOND time this list has drifted.
# Survived once, as written: it changed a bullet's WORDS, and the tripwire counts bullets.
# That is a fair result rather than a gap -- `store_requirements_test.dart` says in as many
# words that it cannot judge whether the sentences are honest. These two invert what it does
# claim: one stored item, one bullet, and a summary sentence that names the same number.
mutate "privacy: a stored item loses the bullet naming it" \
  lib/src/ui/privacy_screen.dart \
  "            _bullet(
              theme,
              'The time this app last told you it needs signing in again, so '
              'that it reminds you about once a day rather than every fifteen '
              'minutes.',
            )," \
  ""

# The count word and the bullets can disagree in the other direction, and the sentence that
# carries the number is also the one promising encryption, backup exclusion and deletion by
# "Forget this PC" -- so a wrong number there is wrong about four claims at once.
mutate "privacy: the summary counts fewer items than it lists" \
  lib/src/ui/privacy_screen.dart \
  "'All four are held in Android\\'s encrypted store, under a key that cannot '" \
  "'All three are held in Android\\'s encrypted store, under a key that cannot '"

# A state-changing control must not be reachable by a GET. nestwatch routes `/api/lock` as
# a POST, so this does not merely change a verb -- it stops the lock happening at all,
# while the app reports success.
mutate "lock: the screen lock is sent as a GET" \
  lib/src/api/nestwatch_api.dart \
  "    final (response, _) = await _send('POST', '/api/lock');" \
  "    final (response, _) = await _send('GET', '/api/lock');"

# The 500 body is only ever "operation failed", so the call site is the one place that
# knows what was attempted. Falling back to the generic sentence tells a parent whose PC is
# simply sitting at its sign-in screen that something went wrong with it.
# Survived once, because it replaced only the first line of a multi-line string and the
# tests assert on the second. The decision being inverted is "this call site knows what was
# attempted, so it says more than the generic sentence" -- so the whole argument goes, and
# what is left is exactly what `_requireOk` falls back to.
mutate "lock: a failure stops naming the reason there is one" \
  lib/src/api/nestwatch_api.dart \
  "      whenOperationFails:
          'That PC could not lock its screen.\\n\\n'
          'The usual reason is that nobody is signed in to it right now — in which '
          'case it is already showing the Windows sign-in screen, and there is '
          'nothing to lock.'," \
  "      whenOperationFails: 'That PC could not carry out the request.',"

# Locking has no undo on this side -- nestwatch publishes no "unlock", deliberately, because
# a machine is unlocked by the person sitting at it. Acting on a cancelled dialog takes a
# child's screen away on a tap the parent explicitly withdrew.
mutate "lock: cancelling the confirmation locks the screen anyway" \
  lib/src/ui/screenshot_screen.dart \
  '    if (confirmed != true || !mounted) return;' \
  '    if (!mounted) return;'

# `curfew_note` ends "Use \"Later bedtime tonight\" on the Curfew card to move bedtime
# itself." The control is named by a sentence written in the other repository, so its label
# is not this app's copy to choose -- a parent reads the instruction and then looks for the
# thing it named.
mutate "bedtime: the control stops answering to the name the server gives it" \
  lib/src/ui/time_requests_screen.dart \
  "const String laterBedtimeLabel = 'Later bedtime tonight';" \
  "const String laterBedtimeLabel = 'Extend bedtime';"

# That PC formats the new bedtime from its own trusted clock, and `unwrap_or_default()`
# means it can send nothing. Taking the branch away renders "Bedtime is null tonight." --
# and the fix a reader reaches for next is to compute now+30 here, which is a phone
# disagreeing with the clock that actually enforces bedtime.
mutate "bedtime: a time the server did not send is rendered anyway" \
  lib/src/ui/time_requests_screen.dart \
  'String bedtimeConfirmation(CurfewExtension extension) => extension.until == null' \
  'String bedtimeConfirmation(CurfewExtension extension) => false' \

# The debounce, inverted rather than removed: this endpoint is NOT idempotent. `extra_until`
# accumulates -- each call adds to the live extension rather than replacing it -- so two
# taps really are two hours of bedtime.
mutate "bedtime: the control is tappable only while it is already working" \
  lib/src/ui/time_requests_screen.dart \
  '                onPressed: _extending ? null : _askLaterBedtime,' \
  '                onPressed: _extending ? _askLaterBedtime : null,'

# The whole reason this app is allowed to offer the control. nestwatch computes
# `budget_note` because this endpoint shipped "with the opposite hole" from `curfew_note`:
# a parent whose child has no screen time left pushes bedtime back, is told it worked, and
# watches the PC lock anyway.
mutate "bedtime: the budget note is dropped, restoring the hole it was written to close" \
  lib/src/ui/time_requests_screen.dart \
  '        _bedtimeNote = extension.budgetNote;' \
  '        _bedtimeNote = null;'

# The note said bedtime would take the minutes back. Once bedtime has moved that has stopped
# being true, and leaving it up argues with the confirmation beside it.
mutate "bedtime: the note that was acted on is left standing" \
  lib/src/ui/time_requests_screen.dart \
  '        _curfewNote = null;
' \
  ''

# The number the parent chose IS the request. A path and a verb assert just as well for a
# call that always asks for the same thing.
mutate "bedtime: the minutes chosen are not the minutes sent" \
  lib/src/api/nestwatch_api.dart \
  "      '/api/curfew/extend',
      jsonBody: {'minutes': minutes}," \
  "      '/api/curfew/extend',
      jsonBody: {'minutes': 1},"

# Revoking your own session succeeds, answers `was_current: true`, and the next request on
# that cookie is a 401 -- all three measured against a live v0.7.0 on 2026-09-07. Treating
# it as somebody else's device leaves a parent on a list that cannot be refreshed.
mutate "sessions: signing yourself out is treated as signing out somebody else" \
  lib/src/ui/sessions_screen.dart \
  '      if (outcome.wasCurrent) {' \
  '      if (false) {'

# A 404 is a race, not a fault: another device got there first, or that PC restarted and
# every handle went stale, because the salt is per process. Letting it throw turns somebody
# else's success into an error in front of a parent.
mutate "sessions: a handle that matched nothing is reported as a failure" \
  lib/src/api/nestwatch_api.dart \
  '    if (response.statusCode == HttpStatus.notFound) {
      return const SessionRevocation(acted: false, wasCurrent: false);
    }' \
  ''

# There is no undo: the device has to be handed the control password again. A cancelled
# dialog must not sign anything out.
mutate "sessions: cancelling the confirmation signs the device out anyway" \
  lib/src/ui/sessions_screen.dart \
  '    if (ok != true || !mounted) return;' \
  '    if (!mounted) return;'

# `last_seen` is derived as `expires - SESSION_IDLE_DAYS` and the sliding expiry saves every
# five days, so it cannot support a day. Rendering it through `ago` prints "3 d ago" off a
# number nobody measured to that precision -- the `used_mins: 0` failure in a new costume.
mutate "sessions: last-seen is rendered at a precision the number does not have" \
  lib/src/ui/relative_time.dart \
  "  if (d.inDays < 7) return 'Active this week';" \
  "  if (d.inDays < 7) return ago(lastSeen, now: now);"

# A missing `was_current` must read as false. Inverting it signs a parent out of the app
# because they signed out a device they are not holding.
mutate "sessions: an absent was_current is read as yourself" \
  lib/src/api/nestwatch_api.dart \
  "          (jsonDecode(body) as Map<String, dynamic>)['was_current'] == true," \
  "          (jsonDecode(body) as Map<String, dynamic>)['was_current'] != true,"

# ------------------------------------------------------------------- a PC that moved
#
# The whole fix is one comparison, and inverting it is both halves of the bug at once:
# reconnect silently to a certificate that does NOT match, and stop to ask a human about
# one that does. The first is the security claim, the second is the reason M22 was filed.
mutate "moved PC: a certificate that does not match is the one we reconnect to" \
  lib/src/pairing/pairing_controller.dart \
  "      if (known != null && known.fingerprint == observed) {" \
  "      if (known != null && known.fingerprint != observed) {"

# The old behaviour, which is what makes this worth defending: seeing the same certificate
# at a new address relabelled a QR-verified PC as merely trusted-on-first-use, permanently.
mutate "moved PC: re-addressing downgrades the trust that was already established" \
  lib/src/pairing/pairing_controller.dart \
  "        known.provenance," \
  "        PinProvenance.trustedOnFirstUse,"

# Same server, so the cookie is still its cookie. Dropping it turns a lease change into a
# password prompt -- the app asking a parent to fix something that is not broken.
mutate "moved PC: the session is dropped, so the move costs the control password" \
  lib/src/pairing/pairing_controller.dart \
  "        cookie: await _sessions.load()," \
  "        cookie: null,"

# The pairing did not happen again; only the address changed. Nothing in lib/ reads
# `pairedAt` today, which is exactly the condition under which a stored fact rots.
mutate "moved PC: a change of address is recorded as a fresh pairing" \
  lib/src/pairing/pairing_controller.dart \
  "      pairedAt: pairedAt ?? _now()," \
  "      pairedAt: _now(),"

# `restorePin` runs once per launch, so a pin dropped here stays dropped until the app is
# restarted -- over a failed request, for a certificate nothing has cast doubt on.
mutate "moved PC: a failed reconnect throws away the pin it already had" \
  lib/src/pairing/pairing_controller.dart \
  "        pairedAt: known.pairedAt,
      );
    } on NestwatchException catch (e) {
      _emit(PairingFailed(e.message));" \
  "        pairedAt: known.pairedAt,
      );
    } on NestwatchException catch (e) {
      _overrides.distrust();
      _emit(PairingFailed(e.message));"

# ---------------------------------------------------- what agreeing costs, and saying so
#
# Everyone who reaches the fingerprint screen holding a pairing is there because the
# certificate is not the one on file. Dropping the identity on the way to that screen is
# the state it was in before, and it reads as a first pairing.
mutate "replacement: the screen is not told a pairing would end" \
  lib/src/pairing/pairing_controller.dart \
  "      _emit(PairingNeedsFingerprintCheck(invite, observed, replacing: known));" \
  "      _emit(PairingNeedsFingerprintCheck(invite, observed));"

# "Trust this PC" is true of a first pairing and quietly incomplete of a replacement.
mutate "replacement: the button stops naming what it will do" \
  lib/src/ui/pairing_screen.dart \
  "    : 'It matches — replace the paired PC';" \
  "    : 'It matches — trust this PC';"

# Two ordinary explanations with no third read as reassurance on the one screen whose
# entire reason for existing is that only the parent can tell three stories apart.
mutate "replacement: the warning drops the reason it is a warning" \
  lib/src/ui/pairing_screen.dart \
  "      'new certificate made for it. It is not expected otherwise — anything on the '
      'network can answer for an address, which is what the comparison below is for.\n\n'" \
  "      'new certificate made for it.\n\n'"

# The consequence the screen never used to state at all.
mutate "replacement: the warning stops saying the old PC has to be paired again" \
  lib/src/ui/pairing_screen.dart \
  "      'Trusting this one ends the pairing with \${replacing.authority}, and that PC would '
      'have to be paired again.';" \
  "      'Trusting this one connects to it instead.';"

# -------------------------------------------------- the two data tabs, now that they draw
#
# Neither screen carried a mutation until 2026-09-08, because neither was ever rendered:
# `M19` counted 13 of 19 unmutated files under `lib/src/ui/`. These four are decisions those
# screens make about what a parent is shown, and `data_screens_test.dart` draws both against
# the vendored captures of what nestwatch actually sends.

# Anyone who reads a time code can spend it, so revealing it is a deliberate act.
mutate "time codes: the code is on screen before anybody asked for it" \
  lib/src/ui/time_codes_screen.dart \
  "          shown ? code.code : '•' * code.code.length," \
  "          code.code,"

# "A card that reads '0, 0, 0' every evening is a card that stops being read, and this one
# has to still be noticeable on the evening it is not zero."
mutate "usage: what was refused is shown on the evenings there was nothing" \
  lib/src/ui/usage_screen.dart \
  "          if (usage.refused.any) _refusedSection(context, usage.refused)," \
  "          _refusedSection(context, usage.refused),"

# An empty list with no explanation reads as "nothing was used", which is the opposite of
# what a missing focus watcher means.
mutate "usage: the empty list stops saying why it is empty" \
  lib/src/ui/usage_screen.dart \
  "          if (usage.focusMissing) _focusMissingNotice()," \
  "          if (!usage.focusMissing) _focusMissingNotice(),"

# Granted minutes change what the headline number means, so the line exists on the days
# there were any -- and would be noise on the days there were not.
mutate "usage: every day claims extra minutes, including the zero ones" \
  lib/src/ui/usage_screen.dart \
  "          if (usage.extraMinutes > 0) ...[" \
  "          if (usage.extraMinutes >= 0) ...["

# ------------------------------------------------------- the frame, and a row with no give
#
# The shape this row had until 2026-09-08: two inflexible children and a Spacer between
# them, which cannot rescue anything because a Spacer only absorbs slack. Found by
# rendering the screen at 320x568 for the first time.
mutate "requests: the header row has nowhere to give on a small phone" \
  lib/src/ui/time_requests_screen.dart \
  "                Expanded(
                  child: Text(
                    '\${request.minutes} more minutes',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                )," \
  "                Text(
                  '\${request.minutes} more minutes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),"

# Only `serverOlder` bands a screen: it is the one case where something is going to break
# and the parent holds the fix. Widening it puts a strip in front of every parent whose PC
# is merely ahead of their phone, which is the ordinary state after a nestwatch release.
mutate "home: every version disagreement bands every screen" \
  lib/src/api/server_contract.dart \
  "  bool get isWarning => agreement == ContractAgreement.serverOlder;" \
  "  bool get isWarning => agreement != ContractAgreement.agreed;"

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

summary

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
