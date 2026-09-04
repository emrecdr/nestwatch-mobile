# Changelog

Notable changes to the nestwatch phone app. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[docs/VERSIONING.md](docs/VERSIONING.md).

Nothing has been released yet, so everything is still under `[Unreleased]`. See
`docs/VERSIONING.md` for why the version is `0.x`.

## [Unreleased]

### Added

- Pairing by QR code and by trust-on-first-use, both ending pinned to the PC's certificate.
- Certificate pinning through `HttpOverrides.global`, with the pin as the sole authority:
  a fingerprint match admits the connection and nothing else is consulted.
- Time requests, time codes, usage and screenshots, each behind the pinned client.
- Server-sent events (`GET /api/events`), so a change made elsewhere is reflected without
  polling.
- Notification actions that approve or deny a time request from the notification itself.
- Background polling on a 15-minute floor — WorkManager's minimum, and promising less
  would be promising something the platform declines to keep.
- Certificate-expiry warning, because a pinned phone keeps working against a lapsed
  certificate while the browser dashboard hard-fails, so the phone is the only client left
  able to explain.
- An iOS build, with notification categories, the local-network usage description, and
  `BGTaskScheduler` identifiers.
- `FLAG_SECURE` on Android, keeping the child's screen out of the recents thumbnail.
- First rendering tests for the UI layer (`test/screen_render_test.dart`).
- **The usage screen says which routine is running.** nestwatch 0.6.0 sends
  `active_routine` — the name of the scheduled routine whose settings are in force, or null
  when the base rules are. Without it the budget can change at 16:00 with nothing on screen
  accounting for it, which is a defect this app had and could not have found by itself: the
  number was correct and unexplained. Their reason for sending it is quoted where it is
  read, because it applies more to a phone than to the dashboard — the phone is where a
  parent looks when something seems wrong.
- **"Refused today", on the evenings there is anything to say.** That PC declines several
  things a day and gets them right — a clock moved to shift the day boundary, a second
  midnight rollover, a shutdown cancelled with `shutdown /a` — and every one of those went
  to a log inside an ACL-hardened folder needing an Administrator console on the child's
  PC. The record existed exactly where a parent checking from their phone could not reach
  it. It is counts, never a list: all three are things a child can repeat on a timer, and a
  row per occurrence would hand the person being limited a way to rotate the history out.
  <br>Hidden entirely when the total is zero, which is nearly every evening — a section
  reading "0, 0, 0" is one that stops being read, and this has to still be noticeable on
  the evening it is not zero. The wording is copied from the dashboard rather than invented,
  so one event has one name across both surfaces, and `refusal_lines_test.dart` holds the
  constraint that makes the card safe to show the child as well: it states what the tool
  did, never what anyone meant by it. A family that genuinely crossed a time zone produces
  the same counts as a clock moved on purpose, and nothing here pretends to tell them apart.

### Fixed

- **A PC running a nestwatch older than 0.4.0 signed the parent out, in a loop.**
  `/api/events` arrived in 0.4.0, so an older PC answers 404 forever. `ServerEvents`
  correctly treated that as permanent — and reported it through the same `onFatal`
  callback as a lapsed session, which `HomeScreen` had wired to `signOut()`. Because the
  home screen re-mounts and restarts the stream once the password is re-entered, that was
  not one sign-out but a cycle with nothing to end it, against a PC answering every other
  route correctly. The callback is now `onSessionLost` and fires only for a lapsed
  session; a missing endpoint stops the stream and leaves the 60-second poll — which
  exists for exactly this — carrying the screens.
- **Scanning the wrong QR code produced one working tab and three blaming a VPN.** nestwatch
  0.6.0 can mint two kinds of pairing — the parent's, and a bounded one for an integration
  that pushes earned time — and the two links are *byte-identical in form*, because the
  scope is recorded on that PC and never in the URL. Handed the integration one, this app
  paired successfully and then came apart pointing at the wrong thing: an integration
  session may reach `GET /api/usage/today`, so Today showed real figures, while Requests,
  Screen and Codes each got a 403 that this app reported as "turn off your VPN". Turning it
  off would never have helped, and nothing on screen mentioned pairing.
  <br>`GET /session` now reports `scope`, so the app reads it and refuses at pairing time
  with the actual remedy — run `nestwatch pair` and scan that code instead. Every path that
  reaches a connected state passes through one gate rather than three copies of a check,
  because the path most likely to be forgotten is the restore at launch, where the wrong
  pairing arrives already stored and is never scanned again.
  <br>Unrecognised kinds and an explicit-null scope are refused too: on a server that
  reports scopes, silence is a session minted before they existed, which that PC refuses
  anyway. A server too old to send the field at all is exempt — refusing there would lock
  the app out of every PC that has not upgraded, over a field it never claimed to send, and
  `ContractCheck` already says that PC is behind.
- **Two different 403s were reported as the same one.** `require_lan_peer` returns a bare
  status with no body; the scope gate returns `{"error": ...}` naming what the pairing may
  do. The app drained the body and assumed the first, so it could not have told them apart
  even in principle. It reads the body now. Found while checking the first item — and the
  test stub had the same fault, answering `{"error":"forbidden"}` for a LAN refusal, a shape
  no nestwatch has ever sent.
- **A screen reader was told the child's desktop was current when it could be hours old.**
  The screenshot's accessible label was built from a *relative* time — "just now" — computed
  once when the widget last rebuilt. That screen is the only one whose poller can be stopped
  while its content stays up, and `_frameAt` is set immediately before the rebuild, so the
  label always evaluated to "just now" and then nothing recomputed it. The visible line
  said "Frame from 14:32:07" and stayed true; the spoken one did not. Both now come from
  one function and carry the same absolute time, which makes no claim about *now* and so
  has nothing to go stale. It also puts the app back on the usual convention instead of
  inverting it — published guidance is relative for the visible label and absolute for
  assistive technology, and this screen had those the wrong way round.
  <br>Found while checking whether nestwatch 0.6.0's own screen-reader fix applied here. It
  does not: theirs was a live region announcing a counter 61 times a minute, and `liveRegion`
  appears nowhere in this app. The phone had the opposite defect — announced too rarely to
  ever be corrected — reached from the other direction.
- **A grant that bedtime was going to swallow was reported as a plain success.** Screen
  time and bedtime are independent limits on that PC, so approving a time request during a
  curfew window adds minutes the child cannot use. nestwatch says so in `curfew_note` on
  the approve response, and this app discarded the body with `final (response, _)` —
  measured, the string appeared nowhere in this repository. It now reaches the parent: as
  a notice on the requests screen that waits to be dismissed rather than a snackbar that
  times out, and as a second notification when the answer came from a lock screen, where
  the app previously said nothing at all on success. The sentence is passed through
  verbatim; that PC owns the verdict, because it owns the clock the enforcer reads.

### Tooling

- Continuous integration (`.github/workflows/ci.yml`): analyze, format, tests, both platform
  builds, the dependency audit, the version check, and the mutation audit.
- The contract job checks out `emrecdr/nestwatch` and runs `tool/check_golden.sh` against it
  on every push — the cross-repo gate had previously needed both checkouts on one machine
  and a person choosing to run it (see `nestwatch#O72`).
- `tool/check_version.sh`, holding `pubspec.yaml`, `CHANGELOG.md` and the git tag together,
  and reporting the contract version separately because it is not this app's.
- `tool/check_findings.sh` now separates a same-file dangling reference (an error here, exit
  1) from a cross-repo one (not decidable here, exit 3) instead of failing on both.
- Three mutations covering the two fixes above, and a re-anchored fourth. The audit
  reported `ANCHOR MISSING` for that one rather than counting it as a pass — which is the
  third outcome earning its keep: `approveTimeRequest` returning a `Decision` turned the
  line it named into a block, and a run that had called it `killed` would have been lying.
- `tool/mutate.sh` says at the top not to edit `lib/` while it runs. `restore` replaces the
  whole tree rather than the mutated file, so an edit made mid-run is silently reverted from
  a snapshot taken before it — including in files the script never mutates. Found by losing
  one.
- **`tool/mutate.sh` repeats survivors at the end**, so a caller that pipes it through
  `tail` still learns *which* mutation survived. A run reported `survived=1` with the name
  already scrolled past, and identifying it meant re-running four mutations by hand. The
  obvious fix — piping through `grep` — is worse than it looks on this machine, where a
  bare top-level `grep` gets rewritten and turned an entire audit's output into
  `error: unknown option '-G'`. A summary the script prints itself needs no filter at the
  call site. Guarded for bash 3.2, where `${arr[@]}` on an empty array is an unbound
  variable under `set -u`, and watched to fire in both the empty and non-empty case.
  <br>Found by breaking it: that change was made *while an audit was running*, which the
  file's own header warns against because bash reads a script incrementally. The run died
  on a variable declared in a line it had already passed. The `trap` restored `lib/` intact,
  which is the half that mattered.
- **The mutation audit caught a comment arguing for something no test defended — mine.**
  `Refusals.total` is taken as nestwatch sends it rather than re-added from the three parts,
  and a doc comment said so at length. Replacing it with a local sum **survived**: the test
  making that argument built a `Refusals` by hand, so it exercised the rendering and never
  once went through `fromJson`, which is where the decision lives. The parts and the total
  agree in today's payload, so nothing else noticed. The replacement test parses JSON whose
  total exceeds the parts — not a hypothetical server but the next one, since the whole
  reason the field is sent is the day a fourth kind of refusal is counted and only the sum
  moves.
- The first wire coverage of a **mutating** response. All nine golden files are `GET`
  payloads on both sides of the contract, which is how a field on the approve reply went
  unread with every gate green; the approve and deny bodies are now stubbed from shapes
  captured off a live 0.5.1 on 2026-09-02.

### Verified

- The pin refuses a wrong certificate **before any body is sent** — observed as 0
  application bytes at a byte-counting sink, against a control that saw 255 bytes with the
  marker header once the sink's own certificate was pinned.
- ATS does not govern `dart:io`, settled inside a running iOS app rather than from
  documentation.
- Alignment with nestwatch **0.6.0**: nine golden files byte-identical, 11 contract checks,
  and all eight live harnesses green as of 0.5.1. `testedAgainst` moved to `0.6.0` **with**
  the files, which is the rule that constant exists under — the goldens were taken from
  `git archive origin/main`, not from the sibling working tree, which was three commits
  past what CI can see and moved twice more while this was written.
- **`curfew_note` observed on the wire, with a control.** A dev nestwatch 0.5.1 was
  installed on a throwaway port on 2026-09-02, a request submitted through `POST
  /time-request` and approved twice. With bedtime off the reply was
  `{"curfew_note":null,"minutes":30,"ok":true}`; with a curfew window covering the current
  time, the same call returned the sentence. The control matters as much as the test — a
  reader that cannot tell `null` from a string would satisfy one and warn on every grant.
  <br>The first attempt measured nothing: a `wire_sink.py` left listening on the intended
  port by an earlier harness run answered `ok` to every path, and my server had bound the
  wildcard address and lost to the more specific bind. "ok" reads like success, which is why
  the run was repeated on a port checked to be free and against `/session` returning a real
  `{"authenticated":false,"version":"0.5.1"}` before anything was concluded.

### Known gaps

Tracked in [docs/OPEN-FINDINGS.md](docs/OPEN-FINDINGS.md). The ones between here and a
store release are `M7` (Play Console paperwork), `M15` (iOS local-network privacy, unproven
on hardware) and `M12` (no screen-reader map of any screen).

[Unreleased]: https://github.com/emrecdr/nestwatch-mobile/commits/main
