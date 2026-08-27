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

### M2 · Three test files stand up a TLS server, and the fourth copy is where the idiom will drift

`pinning_socket_test.dart`, `api_wire_test.dart` and `expiry_test.dart` each build a
`SecurityContext`, bind an `HttpServer.bindSecure` on loopback, and register a handler that
records whether it ran. `test/support/certs.dart` exists precisely because a helper had
nowhere else to live and one test file was importing another.

**Fix.** Move the rig into `test/support/` — a function taking a certificate basename and
returning the server plus a "did the handler run" flag.

**Not done here.** Two review passes have now flagged it and it has stayed cheap to ignore,
which is the honest reason. Worth doing the next time a fourth file needs one, and worth
doing *before* rather than after.

### M3 · Two tests scrape source text, and the discipline is written twice

`flag_secure_test.dart` and `store_requirements_test.dart` both read a non-Dart file, assert
on its contents, and — deliberately — fail rather than skip when the file cannot be found.
That last part is the valuable bit and it is hand-rolled in both.

Source-scraping is the right altitude here rather than a smell: a window flag and a manifest
declaration have no runtime handle a headless test can reach, and both fail silently in
production. But the "cannot read ⇒ fail" rule is one rule.

**Fix.** A `readSourceOrFail(path)` in `test/support/`, used by both.

### M4 · `api_wire_test.dart` steers an eight-branch path chain with three mutable flags

Carried over from the previous review pass, still true. The stub server decides its response
by walking a chain of `if (path == ...)` with booleans set by the test above it, so reading
any one case means simulating the whole file.

**Fix.** A `Map<String, Handler>` keyed by method and path.

### M5 · `prove_events.dart` has never been run

Written this pass, analysed clean, and never executed against anything — no nestwatch 0.4.0
was listening while it was built. It exits 2 with `requireListening` when the port is dead,
so it fails honestly rather than falsely, and that path *was* exercised.

**Trigger.** The next time a dev nestwatch is up (`docs/PLAN.md` §0), run it. Until then
this repo's event-stream evidence is entirely headless: the parser is tested against bytes
this side wrote, and the framing was read out of axum's source rather than off a wire.

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

### M10 · The notification is a dead end, on the app's only loop

A child asks, the phone buzzes, and answering takes six steps: unlock, find the app, find
the tab, find the row, press. `notifications.dart` sets no `actions:` and registers no tap
handler (`onDidReceiveNotificationResponse` appears nowhere, measured 2026-08-27).

`AndroidNotificationAction` exists in the plugin already, and `openBackgroundSession()`
already returns a pinned, signed-in client inside a background isolate — it is how the
fifteen-minute poll works. So the expensive half is built.

**Fix.** Approve and Deny actions, handled in the background isolate, cancelling the
notification on success. Two taps from a lock screen.

**Pairs with `M14`.** Granting from a lock screen with no confirmation is the case that
makes undo necessary rather than nice.

Full reasoning in `docs/UX-REVIEW.md` §1.

### M11 · Away from home reads exactly like a broken PC

`nestwatch_api.dart` builds one sentence for every transport failure and appends
`e.osError?.message` to it, and `PolledScreenState.waitingPane` renders that verbatim.
Nothing in `lib/` consults connectivity — the only `wifi` match in the tree is
`allowWifiLock` (measured 2026-08-27).

For a LAN-only app, leaving the house is not an error. It is the most common thing that
will ever happen, and it currently produces the same screen as a switched-off PC, with an
`errno` string appended that no parent can act on. The careful `require_lan_peer` copy only
fires when the server answers, which off-network it cannot.

**Fix.** Consult connectivity first, and separate the three states a parent acts on
differently: not on Wi-Fi, on a different Wi-Fi, or home and the PC is genuinely down.

Full reasoning in `docs/UX-REVIEW.md` §2.

### M12 · Nothing in the app has a semantic label

`Semantics`, `semanticLabel`, `MergeSemantics` and `excludeSemantics` appear zero times in
`lib/` (measured 2026-08-27). Five `tooltip:` strings are the whole accessibility surface.

Worst three: the screenshot is an `Image.memory` with no label, so the screen whose entire
content is an image announces nothing; the fingerprint is 95 characters of hex read aloud
one character at a time; and Approve/Deny repeat per row with nothing naming which request.

Touch targets are fine — all interactive elements are Material widgets, which enforce 48dp
themselves. Labelling is the part nothing gives you for free.

Full reasoning in `docs/UX-REVIEW.md` §3.

### M13 · No `SafeArea`, and edge-to-edge is no longer optional at API 36

`SafeArea`, `viewPadding` and `viewInsets` appear zero times in `lib/`. Flutter has
defaulted to edge-to-edge since 3.27, and Android removed the opt-out for apps targeting
API 36 — which this app does.

`Scaffold` covers the tabs via the app bar and `NavigationBar`. The exposed screen is
`pairing_screen.dart`: a `SingleChildScrollView` with flat `EdgeInsets.all(20)` whose last
element is the privacy link, which is the one element Play requires to be reachable.

**Reasoned, not observed.** Confirm on a device before changing anything — this is the kind
of claim that is obvious in theory and wrong on hardware.

### M14 · Approve grants minutes with no way back

`time_requests_screen.dart` debounces with `_deciding`, shows a `SnackBar` on completion,
and offers neither undo nor confirmation (measured 2026-08-27).

The server is idempotent under a mutex, so a double tap is safe — that is what the debounce
and the mutex are for, and PLAN §5 asks for exactly it. Neither helps the parent who tapped
the wrong row.

**Fix.** The `SnackBar` already exists; give it an `Undo` action while it is up. Cheaper
and less irritating than a confirmation dialog, and it stops being optional if `M10` moves
approval to a lock screen.

### M15 · The iOS target is scaffolded and has never been built

`ios/` exists, the bundle identifier matches Android's `com.nestwatch.mobile`, the display
name is set, and `Info.plist` carries `NSLocalNetworkUsageDescription` and
`NSCameraUsageDescription` — with **no ATS exception, deliberately**, because the claim
under test is that `dart:io` never consults ATS.

Nothing has compiled. Measured 2026-08-27: Xcode 26.5 lists the iOS 26.5 SDK, but the iOS
**platform** component is not installed, so both `flutter build ios --no-codesign` and a
simulator run fail with *"iOS 26.5 is not installed. Please download and install the
platform from Xcode > Settings > Components."* The only simulator runtime present is 18.2,
left over from an older Xcode.

**Unblock with** `xcodebuild -downloadPlatform iOS` (several GB), or Xcode → Settings →
Components.

Then, in order:

1. `flutter build ios --no-codesign` — does it even compile.
2. `flutter test integration_test/pinning_on_ios_test.dart -d <simulator>` — **the ATS
   question**. Written, analyser-clean, never run. If ATS were in `dart:io`'s path, a
   self-signed certificate on a bare IP could not connect and these fail.
3. On **real hardware**, not the Simulator: local-network privacy. PLAN §7 is explicit that
   the Simulator does not implement it, and that a local-network call attempted in the
   background while the permission is undetermined "is denied silently without even
   recording the denial" — which is the notification path failing invisibly.

**Two things that are not merely untested but different on iOS.** `workmanager_apple` uses
BGTaskScheduler, which the OS schedules at its own discretion — the honest Android promise
of "within about fifteen minutes" is not true there and the copy would have to change. And
the opt-in "watch now" tier has no iOS equivalent at all; `dataSync` foreground services do
not exist.

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
