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

### Verified

- The pin refuses a wrong certificate **before any body is sent** — observed as 0
  application bytes at a byte-counting sink, against a control that saw 255 bytes with the
  marker header once the sink's own certificate was pinned.
- ATS does not govern `dart:io`, settled inside a running iOS app rather than from
  documentation.
- Alignment with nestwatch 0.5.1: nine golden files byte-identical, 11 contract checks, and
  all eight live harnesses green.

### Known gaps

Tracked in [docs/OPEN-FINDINGS.md](docs/OPEN-FINDINGS.md). The ones between here and a
store release are `M7` (Play Console paperwork), `M15` (iOS local-network privacy, unproven
on hardware) and `M12` (no screen-reader map of any screen).

[Unreleased]: https://github.com/emrecdr/nestwatch-mobile/commits/main
