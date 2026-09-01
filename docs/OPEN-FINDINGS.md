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

**Two things this repo cannot check for itself, and both bite the entries below.** There is
no CI — no `.github/`, no runner config of any kind — and `.git/hooks/` holds only the
shipped `.sample` files (checked 2026-08-27). So `flutter test`, `tool/mutate.sh`,
`tool/check_golden.sh` and `tool/audit_deps.sh` are all things a person runs, and "the
suite covers it" always means "when somebody runs the suite".

Last audited against the tree on **2026-08-27**.

---

## Open

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
