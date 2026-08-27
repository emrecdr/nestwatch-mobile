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

`tool/check_golden.sh` reads `RENEW_WARN_DAYS` out of the sibling repo's Rust to keep
`renewWarnDays` honest. It has an `UNREADABLE` branch and both failure modes were watched to
fire — but it is a bespoke reader of another repository's source, which is the channel both
repos retired when `limits.json` was introduced.

Tracked on the other side as **nestwatch `O72`**, which proposes publishing the constant in
`limits.json`. This entry is this side's half: once that lands, vendor the enlarged file and
delete the reader.

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
