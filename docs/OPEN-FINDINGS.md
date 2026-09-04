# Open findings

**Open work only.** Every entry describes something still true of this tree — found by a
review pass or a verification attempt, judged real, and deliberately left undone, with the
reasoning recorded so it does not have to be re-derived and so nobody re-raises what was
already weighed.

Numbered `M##` so an entry can be cited in a commit without colliding with nestwatch's
`O##` in `../nestwatch/docs/OPEN-FINDINGS.md`.

## How to keep this file honest

Same rules as the sibling repo's, for the same reasons:

- **When a finding is fixed, delete its entry.** Not struck through, not moved to a
  "Fixed" section. `git log` holds the history. A dead entry is not harmless — a reader
  budgets attention against the length of the list, and every closed one spends some.
- **When a finding is partly fixed, rewrite it to describe only what is still true.** A
  half-stale entry gets checked, found wrong, and costs the whole file its credibility.
- **When a finding is withdrawn or refuted, say so where it was argued** rather than
  leaving it here. `docs/HARDENING.md` §3 is the worked example: the fix it proposed did
  not exist, and the entry stayed there marked withdrawn instead of moving here.
- **Cite symbols, not line numbers.** `Poller.nudge` survives an edit; a line number is
  wrong within a week and nothing will tell you.
- **Verify before writing, and say how.** Mark measured claims as measured, with the date.

## Writing across the two repos

nestwatch keeps the same file, and the two now cite each other. That makes this a channel,
and a channel needs an address rather than a sentence.

**Cite a counterpart as `repo#ID`** — `nestwatch#O72`, `nestwatch-mobile#M6` — anywhere in
the entry's prose. On an entry that crosses the boundary, open it with one line:

```
> **Cross-repo** · filed by `nestwatch` · blocked on `nestwatch#O72`
```

Only the parts that apply, and only when they are not the default:

| | |
|---|---|
| `filed by <repo>` | omit when this repo wrote it — say it when the other side did, because prose lands under whoever commits and `git blame` will be wrong |
| `blocked on <repo>#<ID>` | this entry cannot start until that one is done |
| `pairs with <repo>#<ID>` | same subject, both sides have work, neither waits |

**`tool/check_findings.sh` follows those references and is the reason they are addresses.**
Both files delete an entry the moment it is fixed. So a reference that resolved yesterday
and dangles today does not mean somebody was sloppy — it means *the other side shipped it*,
and for a `blocked on` entry that is the exact moment the wait ends and the work begins.
`M6` is the worked example: the way this repo learns that nestwatch published the constant
is the `O72` heading disappearing.

A dangling reference is therefore not an error to tidy away. It is the notification, and
the script says so rather than reporting a failure. Its third outcome is the usual one —
without the sibling checkout on the machine, nothing was compared, and it exits 2 saying so
instead of reporting a clean run.

**What runs by itself, and what still waits for a person.** This paragraph used to say
there was no CI of any kind, which was true when it was written on 2026-08-27 and stopped
being true four days later — a claim several entries below still lean on, so it is corrected
here rather than left to rot. `.github/workflows/ci.yml` now runs analyze, format, the
suite, both platform builds, `tool/audit_deps.sh`, `tool/check_version.sh`,
`tool/check_golden.sh` against a fresh `emrecdr/nestwatch` clone, and the mutation audit —
on every push, with no token and nobody choosing to.

What is still a person: `.git/hooks/` holds only the shipped `.sample` files, so nothing is
checked *before* a commit; and the eight `tool/prove_*.dart` harnesses need a live nestwatch
on the LAN, which no runner has. For those, "the suite covers it" still means "when somebody
runs it".

Last audited against the tree on **2026-09-02**.

---

## Open

### M24 · The note now reaches the parent; the control it names is on the other device

> **Cross-repo** · pairs with nestwatch (unfiled — see below)

`curfew_note` is read and shown as of 2026-09-02. Its second sentence is
*"Use \"Later bedtime tonight\" on the Curfew card to move bedtime itself."* — and there
is no Curfew card on the phone, because `PLAN.md` §5 kept curfew in the browser. So the app
now tells a parent something true and points them at a device they may not be near.

**Passing it through verbatim is still right.** The alternative is this app paraphrasing a
verdict computed against that PC's trusted clock, which is the comparison `M6` and
`nestwatch#O72` exist to stop clients making. The fix is to make the sentence true here
rather than to rewrite it: `POST /api/curfew/extend` is published, takes `{"minutes":N}`,
and answers `{"ok","minutes","until":"HH:MM","budget_note"}` — **measured on the wire
2026-09-02** against 0.5.1. A control labelled exactly "Later bedtime tonight" would make
the server's own instruction correct on this screen.

**Not done in the same pass, for one specific reason.** The endpoint validates against
`MAX_REQUEST_MINUTES`, and `limits.json` does not publish it — checked: the vendored file
carries `code_len`, `login_lockout_secs`, `login_max_fails`, `max_active_codes` and
`max_code_minutes`, and nothing else. A free-entry control would therefore need this app to
hold its own copy of a constant that lives in nestwatch's Rust, which is precisely the
fifth reader `M6` is open in order to delete. Preset choices well inside any plausible cap
need no copy and are the way in; that is a design decision worth making deliberately rather
than alongside a bug fix.

**Two things to raise with nestwatch, neither filed there.** That repository has no
`FINDINGS-INBOX.md`, and its working tree has been dirty with another session's changes
every time this was checked — writing into `docs/OPEN-FINDINGS.md` under those conditions
is the exact deadlock this repo's inbox protocol was invented to end. Recorded here
instead:

1. `curfew_note` mixes a fact with a **dashboard-specific instruction**. The fact travels
   to any client; the instruction does not. Splitting them, or dropping the second
   sentence, would make the field portable — and there are now three clients, not two.
2. `MAX_REQUEST_MINUTES` belongs in `limits.json` for the same reason `max_code_minutes`
   already is. Still absent from the pushed file, re-checked at 0.6.0.

A third item stood here — that `tests/golden/` covered no mutating response — and it is
gone because it is done, not because it was dropped. `cdf6630` asserts the exact key set of
both `/api/extra-time` bodies, and their reason for a Rust test over a golden file is worth
carrying: a field-by-field check passes when a field is *added*, and adding one is the
change most likely to be made without thinking about who else reads it. The trigger was a
third consumer — Voortgang, in the `studygo` repository — rather than this app. Same hole.

**Re-measured against 0.6.0 on 2026-09-02**, because a minor bump can move the wire format
and this app now depends on that field: `curfew_note` is still produced at both call sites
in the pushed `src/api.rs` — the approve handler and `extra-time`. The `Decision` reader is
safe, and it is now pinned on their side as well as tested on this one.

### M26 · A version number stood in for a fact the server states outright

**Fixed; kept because the *way* it was found is the reusable part.** The scope gate's
exemption for old servers first keyed on `ContractCheck.serverOlder` — if that PC is behind,
excuse a missing `scope`. It reads fine, it passed seven tests, and it was wrong in a way
no test noticed.

The mutation audit found it. Widening the exemption from `serverOlder` to "anything but
`agreed`" **survived**, because every test in the file happened to use an *agreed* version
or an *older* one; nothing distinguished a PC that is merely newer, or one whose version
this app cannot parse. One test was even named *"and a newer PC sending nothing recognisable
is still refused"* and passed `testedAgainst`, which is `agreed`. The name claimed a case the
input never exercised.

**The deeper fault was upstream of the test.** nestwatch sends `scope` on every answer from
0.6.0 — an object or an explicit null — and documents making absence answerable on purpose:
*"a client can tell 'this build has no scopes' (field absent) from 'your session predates
them' (field present, null) — the second needs re-pairing and the first does not."*
`SessionInfo` parsed only the value, collapsing the two, and then reconstructed the
difference by inferring from a version string. A proxy for a fact already stated.

`reportsScopes` now reads `json.containsKey('scope')`, the gate consults that, and
`ContractCheck` is out of it entirely. Two mutations cover it — swapping the two meanings,
and collapsing presence back into value — and both were watched to die.

**The general shape, which is what makes this worth an entry.** A test whose *name* is
broader than its *input* passes for the wrong reason and reads as coverage forever after.
Nothing in a green suite can find that; the audit found it by changing the code until a
claim stopped being defended. It is the same failure this repo has recorded twice before —
`docs/OPEN-FINDINGS.md` M18 for a scanner that could not match its own needle, and the
`_curfewNote` test that built its object by hand and never went through `fromJson`.

### M25 · The contract moved four hours after CI last saw it, and nothing was watching

Not a defect — a note about the shape of the gap, because it will happen again.

`GET /session` gained `scope` at **23:42 on 2026-09-02**. The last CI run on this repo was
`fa8b3f4` at **19:19** the same evening. So the goldens were correct when they were last
checked and stale four hours later, and this repo had no way to know: the contract job runs
**on push**, and there was nothing to push. A `schedule:` trigger would have caught it
overnight; nothing else in the current setup can.

**Found by the other side telling us.** The nestwatch session sent a message saying the
session goldens were stale. That is a channel, and it worked — but it depends on somebody
over there noticing and choosing to write, which is precisely the property
`tool/check_golden.sh` exists to not depend on. The claim was verified here before it was
acted on (`git archive origin/main`, then the gate), and it was correct.

**Worth deciding, not urgent.** A nightly `schedule:` on the contract job would turn "we
find out when we next push" into "we find out by morning". The cost is a daily run against
a public repo and a red badge on a day nobody touched this one, which is a real cost for a
repo with no release cadence — a red badge that means "the other side moved" reads exactly
like a red badge that means "you broke it", and the whole value of this gate is that its
failures are legible.

**`check_findings.sh` has the same property as `check_golden.sh`, and it showed on the same
day.** Run against `../nestwatch` on 2026-09-04 it reported `O10` and `O34` dangling; run
against `git archive origin/main` it reported everything resolving. Both true — those ids
live only in that checkout's *uncommitted* file, another session's work in progress. So the
sentence `M20` records about the golden checker holds here word for word: it answers about
whichever tree you point it at, and `NESTWATCH_REPO` defaults to a working tree.

Unlike `check_golden.sh`, this one has **no unpushed-tree warning**. It is a smaller risk —
a dangling reference is already documented as a notification rather than an error, and
nothing gets vendored on the strength of it — but the two scripts giving different amounts
of help about the same trap is the kind of asymmetry that gets rediscovered rather than
remembered.

### M23 · Nothing survives leaving the house, and the obvious fix is a privacy change

Screen data lives in `PolledScreenState.data` and nowhere else. Measured 2026-09-02:
nothing under `lib/` writes to the filesystem at all — the pin, the session cookie and the
announced-request ids are the only persisted things, and all three are in the Keystore. So
on a cold start away from home, all four tabs render `waitingPane()`.

`UX-REVIEW.md` §2 established that leaving the house "is not an error, it is the single
most common thing that will ever happen to it".

**This entry's own first version proposed the fix and was wrong, and that is the finding.**
It read: *"the cheap version is one payload, not four — persist the last `UsageToday` with
the time it arrived and render it behind an explicit 'as of 18:42' header."* Cheap in
engineering terms. The policy cost was never checked, and it is disqualifying.

**What is actually in that payload**, from the vendored golden — real server output:

```json
"focused": [{"name": "minecraft", "minutes": 40}, {"name": "chrome", "minutes": 15}],
"pages":   [{"name": "Poki - Free Online Games", "minutes": 13}]
```

That is a child's application and browsing history. `PrivacyScreen` names it, verbatim, as
the child's personal data — *"the list of what they used"* — and then says **"This app
shows you that data and keeps none of it."** Two sentences earlier it says **"This app
writes no files at all."** Both are true of this build; re-verified 2026-09-02, `grep` for
any filesystem write in `lib/` still returns nothing.

So the filed fix would have made three statements in the policy false, written a child's
app-and-browsing history onto a second device, and put it outside the Keystore where the
other three items live. **The right precedent is already in this repo**, at
`PairingController.unpair`: that cleared two of the three things the screen promised to
delete, and its comment states the standard — *"An inaccuracy anywhere else is a bug; in a
privacy policy it is a false statement about data handling, in the document Play requires
to be truthful."*

**And the gap is smaller than the entry claimed.** Away from home a parent does not get a
blank screen: `waitingPane()` renders the sentence `explainUnreachable` produced — which
tells them they are away, that nothing is wrong with that PC, and offers *Try again*. The
missing thing is the *numbers*, not an explanation.

**So this is blocked on a decision, not on engineering**, and the decision is not this
repo's to make. Any cached figure — even aggregates like `used_mins`, which the server
itself treats as the child's own entitled-to-know data on `/status` — needs four things
moved together: the in-app text, the policy at the public URL, the Play Data Safety form
(`M7`), and `unpair()` growing a fourth clear. Doing three of the four is the exact failure
`unpair` already recorded.

Worth knowing before deciding: pending requests must **not** be cached under any variant. A
stale queue invites a parent to approve something already resolved, and the 400 that comes
back is the good case.

### M22 · A moved PC needs an eyeball, for a certificate the app already holds

`ServerIdentity` stores `host` and `port`, and nothing revisits them. Measured 2026-09-02:
no mDNS, Bonjour, multicast or NSD anywhere in `lib/`, `ios/`, `android/`, or in the whole
nestwatch tree. When DHCP moves that PC, the pin is still valid and the app can no longer
find what it is pinned to.

Recovery is "Type the address instead", which carries no fingerprint — so `begin()` takes
the `_observeForFirstUse` branch, calls `_overrides.distrust()`, and asks the parent to
compare 64 hex characters against a Windows console. The stored fingerprint has exactly
three readers (`restorePin`, the background isolate, and two display sites) and is **never**
compared against one observed at a new address, though it would settle the question with no
human involved. `_persistIdentity` then writes `trustedOnFirstUse`, so a PC originally
verified from a QR code is permanently relabelled.

**Three situations share one mechanism**, and two of them should not: first pairing
(verified, correct), same certificate at a new address (provable without a human), and a
genuinely new certificate after `--new-cert` (needs a human, correct). Conflating the
middle case with the last is how a parent gets trained to click through fingerprint
comparisons — the habit `PLAN.md` §5 quotes nestwatch on depending upon them not having.

**`PLAN.md` §7 deferred the sweep "once pinning exists". Pinning exists**, and has since
`prove_pin` observed 0 application bytes against a wrong certificate. The item never moved
into this register because §7 is a plan document, so nothing re-reads it. Two cautions
before building it: on iOS a subnet sweep is the "network scanning" that raises
local-network privacy, which `M15` records as unproven on hardware and *silently denied*
in the background while undetermined; and the smaller fix needs neither a sweep nor a
permission, because the certificate already carries the machine hostname as a SAN and
`cert.rs` calls it "the *stable* half" for exactly this reason. Storing both costs one
field. It does interact with `whereAmI`, which returns `cannotTell` for a non-numeric host.

**`PLAN.md` §5 is half wrong where it says so, and should be corrected in place.** It
claims the app is "immune to the SAN/DHCP problem that breaks the browser today". It is
immune to the TLS half and equally broken on the addressing half, and that sentence is what
makes the problem look solved.

### M21 · Three platform clocks, one already past

Measured 2026-09-02.

| | Here | Current | Consequence |
|---|---|---|---|
| Flutter | 3.44.6 | 3.47.1 | three minors behind; pinned in CI as `FLUTTER_VERSION` |
| Dart | 3.12.2 | 3.13.1 | `sdk: ^3.12.2` already admits it |
| iOS deployment | 14.0 | 15.0 floor | 3.47 lifts the floor 13 → 15; this **must** move |
| Play target API | 36 | 36 | compliant — `flutter.targetSdkVersion` is 36 |
| AGP / Kotlin | 9.0.1 / 2.3.20 | 9.1.0 / 2.4.0 | below 3.47's verified pair |

**The Play clock has run out rather than being close.** Since 31 August 2026 new apps and
updates must target API 36 or be rejected in Play Console, with extensions available only
to 1 November. The code side is compliant; what this changes is that `M7` — store
paperwork only a Play Console can finish — now has a date rather than an intention.

**The structural item is Material leaving the SDK.** 3.47 ships `material_ui` and
`cupertino_ui` as standalone packages and deprecates the in-SDK versions from November.
Every screen here imports `package:flutter/material.dart`. Not urgent, not optional
forever, and much cheaper while the UI is fourteen files than it will ever be again.

Two things land free on upgrade: 3.47 auto-detects Android high-contrast and colour
inversion, which is on `M12`'s side of the ledger.

### M20 · nestwatch is about to send the expiry verdict, which is what M6 was waiting for

> **Cross-repo** · pairs with `nestwatch#O72`

**Seen 2026-09-01, in the sibling checkout's local tree at `8ab193f` — not yet pushed.**
`GET /api/usage/today` gains two fields:

```diff
  "budget_mins": 135,
+ "cert_days_left": 700,
+ "cert_expiring": false,
```

`src/rules.rs:595` computes the second as `cert_days_left.is_some_and(cert::renewal_due)`,
so the **server applies its own threshold and sends the verdict**. Their own test comment
says it plainly: *"Sending `cert_expiring` means the browser compares nothing."*

**This is not what `nestwatch#O72` proposed, and it is better.** O72's fix was to publish
the constant `RENEW_WARN_DAYS` in `limits.json` so each client could apply it. Publishing
the *answer* instead removes the comparison from every client at once, rather than
standardising the input to a comparison each one still performs.

**What it means for `M6`.** That entry waits to delete `tool/check_golden.sh`'s `sed` over
`src/cert.rs`. If the app stops needing the threshold, the `sed` goes — which is M6 closed
by a route M6 did not anticipate. Whether it can is a real question and not a formality:

- Our warning is computed from the pinned certificate's `notAfter`, taken from the
  handshake, and is therefore available on **every** connection. `cert_expiring` arrives
  only with a usage payload, so only on that screen and only when the request succeeds.
- O72 argued this exact point in the other direction about `VALIDITY_DAYS`: the handshake
  figure "describes the certificate in front of it rather than the one this version would
  issue". That reasoning did not stop applying because a new field appeared.
- So the likely shape is that the server's verdict is used to *agree with*, not replace,
  the local one — and that two sources that can disagree is precisely the problem O72
  raised about a third answer. Worth deciding deliberately rather than by whichever lands
  first.

**Landed. They pushed on 2026-09-02** (`52c23e4`), and the contract check went red against
the pushed branch exactly as it should. The golden files are vendored, `UsageToday` parses
both fields, and `models_golden_test.dart` pins them — including `cert_days_left: null` in
the unmeasured fixture, which is the same "could not say" shape as the four nulls beside it.

**No screen reads them, and that is the decision rather than an omission.** The two answers
are not interchangeable:

| | this app's warning | `cert_expiring` |
|---|---|---|
| source | `notAfter` from the TLS handshake | that PC's own `renewal_due` |
| available | every connection, including the pairing screen | only with a usage payload that succeeded |
| whose clock | the phone's | the PC's |

The last row is the interesting one. Both describe **the same certificate** — the pin
guarantees it, since a rotated certificate is refused rather than read. So the numbers can
only disagree if the two clocks do. A disagreement here is not a disagreement about the
certificate; it is the phone and the PC telling different times, which nothing in this app
currently detects and which would quietly distort every "used today" figure on the usage
screen as well. That is worth building deliberately, and it is a different feature from the
expiry warning.

**What this does NOT do: close `M6`.** Tempting, since `cert_expiring` is the verdict and a
verdict needs no threshold — but `renewWarnDays` is still read by
`CertificateExpiry.of()`, which runs from the handshake on screens that never fetch usage.
Deleting the `sed` needs the threshold to be unnecessary, not merely duplicated. It is
nearer than it was; it is not done.

**Then the lesson was ignored by the person who wrote it, within the hour.** The goldens
above were first vendored out of `../nestwatch`'s *working tree*, which had moved to
`511647b` — ahead of the pushed `52c23e4` and carrying `refused` and `refused_total`, a
further change nobody outside that machine can see. Everything passed locally. CI cloned
the pushed branch, found two files drifted, and failed the `contract` job. Re-vendored from
a fresh clone; the pushed shape is what is committed.

**`refused` has since landed, and so has a third field nobody was waiting for.** nestwatch
released **0.6.0** on 2026-09-02 and `origin/main` now carries `refused`, `refused_total`
and `active_routine` in both `usage-today` goldens. All three are vendored, parsed and
pinned, and `testedAgainst` moved to `0.6.0` **with** the files rather than alone, which is
the rule this constant exists under.

**Vendored from the pushed tree, and the guard is why.** Pointed at `../nestwatch` the
checker again reported comparing against local work — that checkout was three commits past
`origin/main` at the time and moved twice more while this was being written, because another
session is committing into it. The goldens were taken from `git archive origin/main`
instead, which is what CI clones and which writes nothing into their repo. Third time on
this subject; first time it cost nothing, because the guard said so before the copy rather
than after the push.

**`active_routine` was the surprise, and it fixes a defect this app had without knowing.**
It names which scheduled routine put today's numbers in force, or is null when the base
rules did. nestwatch's reason for sending it — that without it "the card is a budget that
changes at 16:00 for no stated reason, which reads as a bug in exactly the way an
unexplained number always does here" — applied word for word to the usage screen, which
showed a budget it could not account for. It is rendered under the headline now.

**So it is a guard now rather than a caution.** `tool/check_golden.sh` prints the commit it
compared against — it always did — and now also says when that commit is not in the
checkout's `origin/main`, because printing a SHA relies on somebody recognising which SHA
is published. It reads the local remote-tracking ref rather than the network, so it still
works offline; a stale ref makes it warn about work that *is* pushed, which is the safe
direction to be wrong in. Watched to fire against the working tree and to stay quiet
against a fresh clone.

**The lesson is about the checker, not the fields.** It answers about whichever checkout it
is pointed at, and `NESTWATCH_REPO` defaults to `../nestwatch` — a working tree, which may
hold anything. The same command gives two different true answers. Reading either one as
*the* answer, without saying which tree it came from, is how "we are aligned" gets said
about a state nobody has shipped. Its output does name the commit it compared against; that
line is the part to read.

### M19 · The suite had 253 tests and rendered nothing

**Measured 2026-08-31:** zero occurrences of `testWidgets(` or `pumpWidget` anywhere under
`test/` or `integration_test/`. `lib/src/ui/` is 2,574 lines and every one of them was
checked by reading only. The one file that mentions `testWidgets` —
`test/screen_load_test.dart` — says so in its own header and answers it by lifting one
shared rule out of four screens into pure logic. That closed the rule. It did not render
anything.

This is also visible in the mutation audit: of 39 files under `lib/src/`, 19 carry no
mutation at all, and 13 of those 19 are `lib/src/ui/`. The suite tests logic thoroughly and
draws nothing.

**Partly fixed.** `test/screen_render_test.dart` pumps `PrivacyScreen`, `FingerprintView`,
`Notice` in all three tones, and `PairingScreen` — the largest UI file at 439 lines and the
first screen a parent sees — at 320x568 and 430x932, the iPhone SE floor implied by the iOS
14 deployment target and a large modern phone. Each case asserts **both** directions: that
nothing was thrown or overflowed, *and* that a specific string reached the screen. The
absence half alone would pass for a screen that renders an empty box, which is the exact
failure the file exists to notice.

**The rig was shown to fail before it was trusted**, twice over. A planted throwing widget
and a column 1,600px tall on a 568px screen are both caught by `takeException()`; and
pointing one case at a string the screen does not contain failed with *"built without
throwing, but put ... on screen nowhere"*. The uncovered list caught its own first
omission unprompted — `poller.dart` was missing from both lists and the guard failed until
it was classified.

**What is still not rendered, and why it is a list rather than a sentence.** Nine files
need either a live `NestwatchClient` (`home_screen`, `screenshot_screen`, `polled_screen`
and the three screens it drives) or a platform channel (`notifications_sheet`,
`scan_screen`, `background_promise`). A comment saying so would be true today and silently
wrong the day someone adds a screen, so the test reads `lib/src/ui/` and fails on any file
in neither list — and on any listed name that no longer exists.

**What this does not close, stated plainly because the temptation is to claim it.** It
would *not* have caught the blank white screen on iOS. That was `initNotifications()`
throwing out of `main()` before any screen was built, and pumping a screen never calls
`main()`. A screenshot found that one, and a screenshot is still what finds the next of its
kind. Rendering coverage and running-app coverage are different things, and 268 green tests
say nothing about the second.

### M18 · The dependency audit proved it could read, never that its needle could match

> **Cross-repo** · pairs with `nestwatch#O79`

The mobile half below is done; their half is not, so this stays paired rather than
closed — `nestwatch#O79`'s own open remainder is that `KNOWN_SAFE` excuses a *file* rather
than a *needle*. Two different ways one absence-scan's non-vacuity check can be too weak,
found independently on the same day.

`tool/audit_deps.sh` is this repo's only **absence-asserting** source scan: it claims no
shipped package reaches the network outside `HttpOverrides`. On nestwatch#O79's taxonomy
that is the direction that fails *open* — break it and it reports success.

It already carried a control, added after the previous version of this audit spent months
grepping for `SecureSocket` and matching nothing. But the control asks a weaker question
than the audit answers:

```sh
grep -rqE 'import|class|void|final' "$lib"   # can the grep READ a tree?
grep -rlE "$SUSPECT"               "$lib"   # can $SUSPECT MATCH one?
```

Those are different patterns, and only the second is the claim. **Measured 2026-08-31**
against a fixture holding a real positive: the well-formed pattern found it; a `$SUSPECT`
with one stray `[` returned nothing — grep exits 2 and writes to the stderr this script
discards, so every package reads as clean — while the control passed for both runs and the
script still printed *"so the grep can see."* One mistyped character while adding a term
and the audit goes silent, in the direction that looks like good news.

**Fixed.** Each alternative in `$SUSPECT` is now asserted against a planted positive
before the pub-cache is opened, so non-vacuity rests on a fixture rather than on whatever
the cache happens to hold. `SUSPECT_PATTERN` is overridable for the same reason `CACHE`
and `LOCKFILE` are — the broken pattern above was watched to fire (`DETECTOR FAILED`,
exit 2) rather than assumed to.

**What it still does not cover**, recorded because *"all 7 terms"* reads stronger than it
is: a term is checked against a positive built from itself, so a plausible typo naming no
real API passes — `SocketsButTypoed$$` was tried and did. This closes the pattern going
blind. It cannot close the list being wrong, and nothing mechanical can.

**Why this was worth doing on their finding rather than waiting for ours to fail.** The
audit is exactly the shape nestwatch#O79 describes, and this repo's recurring defect is
the same one: a check that stops checking while still reporting success. It had already
happened here twice — the original `SecureSocket` grep, and mutation anchors going stale
three times. The lesson generalised across repositories before it had to be relearned.

### M17 · The architecture report said "one file move"; it was not

`docs/UX-REVIEW.md` and the published standing review both described the
`pairing ↔ background` cycle as fixable by moving one class. Moving
`SecureSeenRequestStore` out of `pairing/` removed one edge *source* and left the cycle
standing, because the real cause was `pairing_controller` importing the
`SeenRequestStore` **interface** — and its two sibling interfaces live in `pairing/`,
so no single move made the graph acyclic.

What actually fixed it was not a move at all: the controller now takes a
`Future<void> Function()` named for the capability it needs rather than the collaborator
that provides it. Measured 2026-08-31 — `pairing` no longer reaches `background`, and the
graph has no cycles.

**Kept as an entry because the estimate was the finding's weakest part.** "One file move"
was written from a dependency graph without checking what the edge carried, which is the
same error as every other claim this repo has had to withdraw: right about the direction,
wrong about the specifics.

### M1 · The event stream is additive, so it costs traffic rather than saving it

`ServerEvents` holds one connection and nudges the screens early; `PolledScreenState.cadence`
is unchanged at 60 s. Both run. So the phone now makes the same sixty polls an hour **plus**
holds a stream, which is more work than before, not less — an efficiency review pass caught
the arithmetic after `README.md` had already claimed the saving. The README is corrected;
the design is not.

What it does buy is real and was the point: worst-case latency on a new request drops from
60 s to about one.

**Fix.** Lengthen the cadence while `ServerEvents.isReceiving`, back to 60 s when not.

**Not done, and the reason is the interesting part.** The poll exists as a backstop for a
stream that dies quietly — a stream that stops is silent forever and looks exactly like a
house where nothing is happening. Tuning the backstop using a signal from the thing it is
backing up weakens precisely the property it is there for. If `isReceiving` is wrong, the
backstop is long *and* the stream is dead. A safer shape is a slower backstop that never
consults the stream at all — say 5 minutes always, on the grounds that events carry the
urgency — but that is a real behaviour change and wants deciding, not sliding in.

### M2 · Two host tests still build their own TLS server

**Mostly done.** `test/support/tls_server.dart` holds the rig — context, key, bind on port
0, and the `handlerRan` flag that is what most of these tests actually assert.
`pinning_socket_test` and `expiry_test` use it, losing 61 lines between them and keeping
every assertion, including the load-bearing one: a refused handshake means the handler
never ran.

Two remain, and both for reasons rather than inertia. `api_wire_test` needs a routing stub
rather than a fixed responder — the rig deliberately answers one body, because a file that
needs routes should own them. `poll_logic_test` is close enough to convert and was left
until somebody has a reason to open it.

`integration_test/pinning_on_ios_test.dart` cannot share this at all: it runs inside the
app sandbox where `test/fixtures/` does not exist, and reads its certificates from
`inlined_fixtures.dart`. Recorded here so that is not rediscovered as an oversight.

### M3 · The source-reading rule is shared; four data loads still read directly

**Mostly done.** `test/support/source.dart` holds `readSourceOrFail`, and every test that
*asserts on source text* now uses it — `flag_secure_test`, `ios_config_test` and
`store_requirements_test`, six call sites between them. Watched to fail: hiding
`MainActivity.kt` produces four failures naming what went unchecked.

What remains reads files as **data** rather than as source — `certs.dart` decoding a PEM,
`models_golden_test` loading vendored JSON, `expiry_test` and `inlined_fixtures_test`
reading fixtures. A missing file there already throws where it is used, and routing them
through a helper whose whole purpose is a nicer failure message would be ceremony. Left
deliberately, and recorded so the count is not re-raised as duplication.

### M5 · Every harness has now been run live; two skips are the platform, not the rig

**Re-run against nestwatch 0.5.1 on 2026-08-31**, after that release landed. All eight
pass unchanged, including `prove_pin`'s 0-bytes/255-bytes control pair. The audit-log skip
below is now closed too — `prove_timecodes --audit` pointed at the live data directory
runs its two assertions and both pass, so what remains skipping is only the screenshot and
pairing-token pair, and both are the platform.

Recorded separately from `ContractCheck.testedAgainst`, which stays at `0.5.0` **on
purpose**. That constant states where `test/golden/` was captured from, and its own doc
says to bump it *with* the files and never alone. The files did not change — nine compared
byte-identical against the sibling checkout at `837c03f` — so `0.5.0` is still exactly
true, and "verified against 0.5.1" is a different claim that belongs here rather than
folded into a string that means something else. Bumping it because nothing appeared to
change is how the next bump becomes because nothing probably changed.

**Closed.** All eight ran on 2026-08-31 against dev instances built from the sibling
checkout — three nestwatch instances (real, impostor, rotated), the byte-counting sink and
the LAN-gate stub. `prove_pin`, `prove_tofu`, `prove_events`, `prove_login`,
`prove_background`, `prove_screens`, `prove_timecodes` and `prove_rotation`, all passing.

The two that matter most were observed rather than argued. `prove_pin` check 3 saw the
sink accept a TCP connection, fail the handshake, and receive **0 application bytes** —
and check 4, the control, saw **255 bytes with the marker** through the same rig once the
sink's own certificate was pinned. `prove_events` heard nothing across a 17-second
keep-alive window and then heard `requests` and `usage` from a change made on another
connection.

**What still skips, and why it is not the rig:** screenshots are `cfg(not(windows))` in
nestwatch, so a macOS host cannot serve one; and `prove_login`'s token checks need a freshly minted
pairing token, which is single-use with a 15-minute TTL. Each says so aloud.

Two harnesses had to be fixed to get here, and both faults were in the harness rather than
the app. `prove_pin` hardcoded `/tmp/nestwatch-impostor/cert.pem` for its control, so
check 4 could not run against a server installed anywhere else — with checks 1 to 3 already
passed, which is exactly the shape of a control that gets skipped rather than fixed. It
takes `--sink-cert` now and stops rather than proceeding without it. `prove_events` hung on
`await sub.cancel()`, which never returns while an SSE stream is healthy — the server has
no reason to close it. Cancelling first and closing second is worse: the close destroys
the socket and a detached subscription lets `HttpException` reach the zone. No entry was
filed for the app, because it was checked: `ServerEvents` never cancels-then-closes, so
its handler is attached for the stream's whole life.

### M6 · The `sed` over nestwatch's `src/cert.rs` should be deleted, not maintained

> **Cross-repo** · blocked on `nestwatch#O72`

`tool/check_golden.sh` reads `RENEW_WARN_DAYS` out of the sibling repo's Rust to keep
`renewWarnDays` honest. It has an `UNREADABLE` branch and both failure modes were watched to
fire — but it is a bespoke reader of another repository's source, which is the channel both
repos retired when `limits.json` was introduced.

`nestwatch#O72` is the other half, and proposes publishing the constant in `limits.json`.
This entry is this side's: once that lands, vendor the enlarged file and delete the reader.
Nothing here needs doing until then — and the way this repo finds out that day arrived is
`tool/check_findings.sh` reporting that reference dangling, because a fixed entry is a
deleted entry on both sides.

**`nestwatch#O72` is now overtaken on its own subject, though not closed.** They shipped
`cert_expiring` (see `M20`) — the verdict rather than the constant. O72 proposed publishing
`RENEW_WARN_DAYS` so each client could apply it; sending the answer removes the comparison
from every client at once. This entry still waits, because `renewWarnDays` is read by the
handshake path that runs where no usage payload exists.

**Three facts `nestwatch#O72` argues from stopped being true on 2026-08-31**, and the other
side should know before weighing it again. It says, measured 2026-08-27, that this
repository has *"no CI of any kind — no `.github/`, no runner config of any flavour"*; that
*"the client's [CI] never runs this one"*; and that drift *"needs both checkouts on one
machine and a person choosing to run it."*

There is now `.github/workflows/ci.yml`, and because both repositories are public it checks
out `emrecdr/nestwatch` and runs `tool/check_golden.sh` against it on every push and pull
request — no token, no person. The manual gate O72 describes is the thing that changed.

**This does not close O72, and the direction of its argument survives intact.** Its case was
explicitly *"consolidation, not automation"* — one bespoke reader of another repository's
source replaced by a gate already covering five other values. That is still true, and a
`sed` matching `pub const RENEW_WARN_DAYS: u64 = <n>;` is still a reader of their Rust
whether a robot runs it or a person does. What changed is only the *cost of leaving it*,
which O72 gives as a reader *"that only speaks when somebody runs it."* It now speaks on
every push. So this stays blocked on their side rather than becoming urgent.

### M12 · The screen reader still has no map of a screen

**Two of this entry's three original examples were wrong and are gone.** The screenshot
now carries a `semanticLabel` and the decision buttons name the request they answer. The
fingerprint example was withdrawn — `FingerprintView` already renders grouped rows, so a
screen reader was never reading 95 characters as one run.

What is genuinely left is structural rather than per-widget, and needs a device to judge:
no headings, so a screen reader user cannot jump between sections; the four tabs announce
as bare labels; and `Notice` — which carries every warning in the app — has no role, so a
caveat reads exactly like body text. `Semantics(header: true)` and a `liveRegion` on the
warning strip are the likely shapes.

**Not done because it cannot be judged from here.** The remaining work is about how a
screen actually *sounds*, and every claim in the first version of this entry that was
written from the code rather than from the widget turned out to be wrong. This wants
TalkBack and VoiceOver on real hardware, not another read of the source.

**Two things measured on 2026-09-02, so the next reader starts from facts rather than a
count.** `liveRegion` appears **nowhere** in `lib/` — which matters because nestwatch 0.6.0
fixed a screen-reader defect of exactly that kind (a region announcing a counter 61 times a
minute) and the fix does not transfer: this app cannot have that bug, and importing their
remedy would be adding a live region where none exists. And the full spoken surface is
nine strings: two `Semantics` labels on Approve and Deny, six tooltips, and one
`semanticLabel` on the screenshot. Everything but the last is static or bound to a value
that cannot change while it is on screen.

The screenshot label *was* the exception and is fixed — it carried a relative time on the
one screen that stops rebuilding, so it said "just now" about a frame of any age. That is
in `git log`, not here, because it is done.

**Two items are now specific enough to implement in a single sitting, and both were
still left.**
The curfew notice added on 2026-09-02 (`M24`) is the canonical live-region case: it appears
in response to an action, it carries the one message in this app whose whole purpose is to
stop a parent believing something untrue, and a parent who has just moved focus will not be
looking at the top of the list where it lands. `Semantics(liveRegion: true)` is the
annotation. It was **not** added, for two reasons worth keeping: it must not go on the
shared `Notice`, because six of the seven uses are state-derived and would re-announce on
every rebuild of the caveat strip — so it needs its own opt-in flag; and this entry's own
history is a run of accessibility claims written from the code that turned out to be wrong
at the widget. Shipping an announcement nobody has heard would be one more.

The second is **"Refused today"**, and it comes with a precedent rather than a guess: the
dashboard marks that same list `aria-live="polite"` with `aria-atomic="true"`. The phone's
usage screen repolls every 60 s, so the question a device would answer is whether an
unchanged list stays quiet between polls. Flutter announces on a semantics *change*, which
should mean it does — and "should mean" is exactly the kind of claim this entry exists to
stop being written from the code rather than heard.

**One thing that cannot happen here, recorded so nobody imports the fix.** nestwatch 0.6.0
fixed a screen reader being read a counter 61 times a minute, caused by a live region on a
line that changed every second. This app has no live regions at all, so it cannot have that
defect. It had the mirror image — a label that never changed and so was never corrected —
and that one is fixed. Checking whether their fix applied here is how it was found.

### M13 · The bottom inset is handled; the rest was not the problem

**Done, and the entry was half wrong.** Running the app on a simulator and looking at it
settled what reading could not: the **top** is handled — `Scaffold` and `AppBar` place the
title below the notch correctly, so that half of the worry was unfounded.

The bottom is real and is now fixed on the two screens it applies to. `pairing_screen` and
`privacy_screen` own a `Scaffold` with no bottom chrome, so nothing pads for the gesture
bar; both now wrap their scroll view in `SafeArea(top: false)`. The four tab screens never
needed it — they sit above a Material 3 `NavigationBar`, which pads itself.

Verified by running: no `RenderFlex` overflow, no layout error, and the pairing screen
renders as before.

### M15 · iOS builds and the pin holds; local-network privacy is still unproven

**The ATS question is answered.** Measured 2026-08-29 on an iOS 26.5 simulator,
`integration_test/pinning_on_ios_test.dart`: a self-signed certificate on a bare IP — which
ATS would refuse outright — connects through `badCertificateCallback`, a wrong pin is
refused before anything reaches the server, and no pin refuses everything. `Info.plist`
carries no ATS exception, so `dart:io` demonstrably does not consult it. PLAN §7's
reservation, that the inference was "sound but still not documented", is retired.

`flutter build ios --no-codesign --simulator` succeeds. Deployment target is 14.0, raised
from Flutter's default 13.0 because `workmanager-apple` requires it.

**What is still owed, and it is the half a simulator cannot give.** PLAN §7 is explicit
that the Simulator does not implement local-network privacy at all. The proof above uses
loopback, which never leaves the process, so the permission is never consulted. On a real
iPhone, reaching a LAN address raises a prompt, and a call made in the background while
that permission is undetermined "is denied silently without even recording the denial".
That is the notification path failing invisibly, and only hardware can show it.

**Also unproven on iOS:** pairing by QR (needs a camera), the background poll actually
firing, and whether `NSLocalNetworkUsageDescription` reads well in the real prompt.

**Two things are different rather than untested**, and the app now says so rather than
pretending otherwise — see `lib/src/ui/background_promise.dart`. `workmanager_apple` uses
BGTaskScheduler, whose interval is advisory: iOS decides from usage and battery, it can be
far longer than fifteen minutes, and **a force-quit stops scheduling entirely**. Apple's own
remedy is a push with `content-available`, which this design forbids — the monitored PC
makes no outbound connection, which PLAN §7 calls "not deferred, it is impossible". And the
"watch now" tier is hidden on iOS: it is a `dataSync` foreground service and iOS has no
equivalent, so a switch that silently did nothing was the wrong answer.

### M16 · The old iOS 18.2 simulator runtime is dead weight

Xcode 26.5 cannot build against it — it was left by an earlier Xcode, and the 26.5 runtime
had to be downloaded beside it. Disk is at 2.4 GB free after that download (measured
2026-08-29), and this repo's own `build/` reached 3.4 GB before `flutter clean`.

Removing the 18.2 runtime would reclaim several GB. Left alone because deleting a simulator
runtime is a system change with a re-download cost, and it is the user's call, not this
repo's.

### M7 · Store paperwork that only a Play Console can finish

None of this is code, and none of it can be checked from here:

- **An upload keystore**, and enrolment in Play App Signing. `android/key.properties.example`
  has the `keytool` invocation. `bundleRelease` refuses until it exists (proven 2026-08-27:
  the `.aab` signed with a throwaway key carries `CN=throwaway`, the fallback `.apk` carries
  `CN=Android Debug`).
- **The `dataSync` foreground-service declaration.** Updates are rejected for omitting it.
- **The privacy policy at a public URL**, matching the in-app text in `PrivacyScreen`, plus a
  Data safety form that agrees with it.

**One thing worth knowing before that form.** This repo declares three permissions; the
merged manifest ships ten (measured 2026-08-27) — `CAMERA`, `WAKE_LOCK`,
`RECEIVE_BOOT_COMPLETED`, `ACCESS_NETWORK_STATE`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_SHORT_SERVICE` and a receiver permission, all arriving from plugins. The
listing shows what the build ships, not what this repo wrote.

### M8 · Three behaviours that need hardware or six hours

Each is defended headlessly and none has been observed where it actually runs:

- **The QR camera path.** Needs a real camera; the emulator's is not a substitute for
  reading a code off a console.
- **`Service.onTimeout`.** API 35, and only after six hours of background foreground-service
  time. No emulator session here can reach it. That `allowAutoRestart: false` prevents the
  restart loop rests on reading `ForegroundService.onDestroy` — and the clean-stop test does
  *not* exercise it, because a Dart-initiated stop skips the restart branch.
- **The VPN 403 message.** Proven against `tool/lan_gate_stub.py`, never against a real VPN
  on a real phone. The stub returns the status; it does not reproduce what Android does to
  the route.

### M9 · `FLAG_SECURE` is asserted in source, never observed

`test/flag_secure_test.dart` proves the line exists, is passed as both value and mask, and
sits in `onCreate`. Nothing here has seen a recents thumbnail actually go blank.

**Trigger.** Next time the app is on a device: background it, open Recents, and look.
