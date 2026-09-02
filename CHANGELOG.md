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
- Alignment with nestwatch 0.5.1: nine golden files byte-identical, 11 contract checks, and
  all eight live harnesses green.
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
