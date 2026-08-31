# Versioning

This app carries **two** version numbers, and conflating them is the failure this document
exists to prevent.

| | Where | What it says |
|---|---|---|
| **App version** | `pubspec.yaml` → `version:` | what this build of the phone app is |
| **Contract version** | `lib/src/api/server_contract.dart` → `ContractCheck.testedAgainst` | which nestwatch release `test/golden/` was captured from |

They move independently. A release of this app that changes only a screen does not touch
the contract version; a nestwatch release that changes a payload moves the contract version
without necessarily moving the app's.

## The app version

`MAJOR.MINOR.PATCH+BUILD`, the Flutter convention. `MAJOR.MINOR.PATCH` becomes
`versionName` on Android and `CFBundleShortVersionString` on iOS; `BUILD` becomes
`versionCode` and `CFBundleVersion`.

- **MAJOR** — reserved for the first release a parent can install from a store. It is `0`
  and stays `0` until then. `nestwatch-mobile#M7` (Play Console) and `#M15` (iOS
  local-network privacy, still unproven on hardware) are what stand in the way.
- **MINOR** — a screen, a capability, or an endpoint this app did not use before.
- **PATCH** — a fix that changes no screen and adds no capability.

`1.0.0+1` was the Flutter template's default and was never edited. It claimed a release
that had not happened, which is the kind of number nobody checks and everybody quotes.

### The build number

`BUILD` must **never decrease** — both stores reject an upload whose build number is not
above the last one they accepted, and neither lets you take it back.

`pubspec.yaml` holds `+1` and is not the source of truth for releases. Release builds pass
it explicitly:

```sh
flutter build appbundle --build-name=0.1.0 --build-number=$GITHUB_RUN_NUMBER
```

`github.run_number` is monotonic for the life of the repository and cannot be rewound by a
rebase, a squash, or a branch — which `git rev-list --count HEAD` all can. That property is
the whole requirement, so it is what the number is taken from.

## The contract version

`ContractCheck.testedAgainst` states **where `test/golden/` was captured from**, not the
newest nestwatch anyone has looked at. Bump it *with* the golden files or not at all.

`tool/check_golden.sh` compares it against the sibling checkout's `Cargo.toml` on
major.minor only, because a patch release does not move the wire format — verified when
nestwatch went 0.5.0 → 0.5.1 and changed no handler, route or payload.

The temptation this rule exists to resist: nestwatch releases, nothing appears to have
changed, and the constant gets bumped to match. Do that once and the next bump happens
because nothing *probably* changed. If the app has been verified against a newer server,
that is a real and useful fact — it goes in `docs/OPEN-FINDINGS.md` (see `M5`), which is
where claims with dates belong.

## Tags and the changelog

A release is the commit tagged `vMAJOR.MINOR.PATCH`. `CHANGELOG.md` keeps an `## [Unreleased]`
section at the top; releasing moves it under a version heading with a date.

`tool/check_version.sh` holds these together and is run by CI. It has the third outcome the
other tools have: asked to check a tag when the checkout has none, it says it could not
check rather than reporting a pass.
