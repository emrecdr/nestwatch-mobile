# Nestwatch mobile client — validated implementation plan

> **Written for a fresh session with no prior context.** Everything needed to start is below:
> absolute paths, how to stand up a dev server, the verified API contract, and the traps.

---

## 0. Project reference

### The existing project

| | |
|---|---|
| **Project path** | `/Users/emrec/Projects/playground/nestwatch` |
| **What it is** | One self-contained Rust binary. Installs as a background service on a child's **Windows** PC and serves a small HTTPS web dashboard to a phone/laptop **on the same Wi-Fi**. Screen-time limits, bedtime curfew, remote control. No cloud, no accounts, no telemetry. The monitored PC makes **no outbound connection at all**. |
| **Repo** | `github.com/emrecdr/nestwatch` |
| **Version / license** | `0.2.3`, MIT, Rust edition 2024 |
| **Toolchain** | Pinned `1.96.0` in `rust-toolchain.toml` (CI and local must agree) |
| **Target platform** | Windows 10/11 for the service; CI test matrix is `ubuntu-latest` + `windows-latest` |
| **Default port** | `8443` (`src/config.rs:17`, `DEFAULT_PORT`) |
| **Dashboard UI** | Alpine.js (CSP build) in `assets/` — `index.html`, `app.js`, `app.css`; built via `web/` (npm) |

### The new project

| | |
|---|---|
| **Suggested path** | `/Users/emrec/Projects/playground/nestwatch-mobile` |
| **Separate git repo** — not a subdirectory of nestwatch. The Rust CI matrix builds on two OSes and runs `cargo-deny`; a Flutter subproject would add unrelated toolchain setup and license-scan noise to every PR. The HTTP API is the contract between them. |

### CLI commands you will use

```
nestwatch run           # HTTPS server in the foreground — THIS IS THE DEV SERVER
nestwatch install       # sets password + TLS cert, installs the service (--port N)
nestwatch pair          # print a QR code to sign in another device
nestwatch fingerprint   # print the TLS cert SHA-256 (to verify a new device)
nestwatch doctor        # check the install
```

Full usage text: grep `home remote control (LAN only)` in `src/lib.rs` (~L376).

### Standing up a dev server to develop the app against

`nestwatch run` serves the real thing in the foreground. `NESTWATCH_DATA_DIR` redirects all state
to a throwaway directory — **honoured only in debug builds** (`src/config.rs:137-140`), deliberately
ignored by the shipped release service, so it cannot be used to redirect where the real service
reads its password hash and TLS key.

```bash
cd /Users/emrec/Projects/playground/nestwatch
export NESTWATCH_DATA_DIR=/tmp/nestwatch-dev
cargo run -- install --port 8443     # sets a password, generates cert, prints the pairing QR
cargo run -- run                     # foreground HTTPS server
cargo run -- fingerprint             # the SHA-256 the app must pin
```

Files created under `NESTWATCH_DATA_DIR` (`src/config.rs:121-131`): `config.json`, `cert.pem`,
`key.pem`, `pairing.json`, `sessions.json`.

**Developing on macOS works for everything the app needs except the screenshot.** The crate compiles
and the server runs on non-Windows — auth, pairing, time-requests and usage are all portable — but
capture has `cfg(not(windows))` branches (`src/control/mod.rs:296,310`). Build the pinning, pairing
and time-request flows on the Mac; test the screenshot screen against a real Windows install.

### Files Phase 1 will modify (absolute paths)

```
/Users/emrec/Projects/playground/nestwatch/src/pairing.rs        # pair_url gains the fingerprint fragment
/Users/emrec/Projects/playground/nestwatch/src/install.rs        # the single pair_url call site (~L292)
/Users/emrec/Projects/playground/nestwatch/tests/origin.rs       # one added test
/Users/emrec/Projects/playground/nestwatch/docs/MOBILE-APP.md    # three corrections
/Users/emrec/Projects/playground/nestwatch/CHANGELOG.md          # prose entry, house voice †
```

† **CHANGELOG.md is being edited by another session** (unrelated capture-path fixes). Add the Phase 1
entry on top of whatever is there; do not assume `[Unreleased]` looks as it did when this was written.

Verify with `cargo test`, plus the gates CI runs: `cargo fmt --check`,
`cargo clippy --all-targets -- -D warnings`, `cargo deny check`.

> ### ⚠️ Citation freshness
>
> **Re-verified 2026-08-26 at HEAD `5b1b8d4`** — all 18 citations in this document checked by
> printing the line and confirming the symbol, not by assuming.
>
> **This branch is in heavy flux.** At time of writing it is ~31 commits ahead of `origin/main`
> across ~44 files, with two other sessions editing concurrently. Expect drift; re-check before
> trusting any line number. The files below changed in just the last two commits
> (`849dc05..5b1b8d4`) — treat their line numbers as already stale and **grep for the named symbol
> instead**:
>
> `assets/app.js` · `assets/index.html` · `src/api.rs` · `src/audit.rs` · `src/control/mod.rs` ·
> `src/control/fake.rs` · `src/lib.rs` · `src/preflight.rs` · `src/screentime.rs` · `src/session.rs` ·
> `src/web.rs` · `tests/api.rs` · `web/test/app.test.js` · `README.md` · `CHANGELOG.md` ·
> `docs/SECURITY.md` · `docs/FOREGROUND-TRACKING.md` · `docs/OPEN-FINDINGS.md`
>
> **No Phase 1 file is in that list.** `src/pairing.rs`, `src/install.rs`, `tests/origin.rs` and
> `docs/MOBILE-APP.md` are untouched across both commits, and every citation below was re-checked
> against `5b1b8d4` by printing the line and confirming the symbol. `CHANGELOG.md` *is* in the list
> (see † above) but is append-only for our purposes.
>
> Cheapest re-check before you start: `grep -n 'fn pair_url' src/pairing.rs`.

### Background reading in the repo

- `docs/MOBILE-APP.md` — the original research this plan validates and corrects
- `docs/SECURITY.md` — the security model the app must not undermine
- `docs/REMOTE-ACCESS.md` — the VPN route, which is the real answer to away-from-home access
- `docs/OPEN-FINDINGS.md` — known limits
- `README.md` — the promise the app inherits ("nothing leaves the house")

---

## 1. Context

`docs/MOBILE-APP.md` recorded research for a native Flutter client and stopped there: nothing was
built, and five claims were filed as unverified. This plan re-checks those claims against primary
sources, corrects what was wrong, and turns the surviving conclusion into work.

The doc's decision — **a native Flutter client, not a wrapped web view and not an installable web
app** — survives validation. Two of its supporting facts do not, and a second pass through the server
found four client-facing traps the doc never reached.

Agreed scope: **server-side fingerprint first, then Android**, Flutter, in a separate repo. Android
first because it is the platform where the one remaining unverified claim (ATS vs `dart:io`) does not
apply at all, where notifications can genuinely work, and where review is a form rather than a person
— so pinning, the API client and the QR flow get proven cheaply before iOS puts that inference on the
critical path.

---

## 2. What validation changed

### The Immich blocker is solvable, and globally

The doc calls the dependency-socket audit "the step that decides whether the project is possible,"
because `Image.network` accepts no custom client. The premise is correct — `_sharedHttpClient` is a
`static final HttpClient()`, and the only injection point, `debugNetworkImageHttpClientProvider`,
sits inside an `assert` and is therefore debug-only. It does not matter, because Dart's `HttpClient`
*factory constructor* consults overrides before constructing anything:

```dart
factory HttpClient({SecurityContext? context}) {
  HttpOverrides? overrides = HttpOverrides.current;   // Zone.current[_token] ?? _global
  if (overrides == null) return _HttpClient(context);
  return overrides.createHttpClient(context);
}
```

`_sharedHttpClient` is a lazily-initialised static, first touched when an image resolves — long after
`main()`. Setting `HttpOverrides.global` at the top of `main()` therefore pins `Image.network` and
every other `dart:io` consumer in the process.

This demotes step 2 from a go/no-go gate to a bounded check with a known answer: does any dependency
**bypass `dart:io`'s `HttpClient`** — i.e. `cupertino_http`/`cronet_http` (platform stacks, ATS-bound)
or a raw `SecureSocket`? Keep the dependency list short and the answer stays no. One caveat: a
dependency calling `HttpOverrides.runZoned` internally would shadow the global inside its own zone.
Low risk, worth grepping for once.

### `flutter/flutter#2696` is closed, not "open since 2016"

The doc uses its open state as evidence the migration never landed. Wrong citation — but the
conclusion is now better supported than it was: security research from 2024–2026 documents Flutter
compiling BoringSSL into the app binary and ignoring both the system trust store and the system proxy
on **both** platforms. Observation beats inference from an issue tracker.

### SPKI pinning would buy nothing here

Worth checking, because SPKI pinning normally survives certificate rotation. It does not here:
`cert::generate` calls `KeyPair::generate()` fresh on every run (`src/cert.rs:41`) and overwrites both
files, so the key changes with the cert. Leaf-DER pinning is correct, and it matches `src/cert.rs:134`
byte for byte with no conversion.

### `VALIDITY_DAYS = 825` is right — checked, because it looked wrong

Apple's better-known limit is 398 days, which would have made this a live bug on every parent's
iPhone. It is not: 398 binds only certificates chaining to **preinstalled** roots. Self-signed and
private-CA certificates are exempt from 398 but still bound by 825, which is exactly what
`src/cert.rs` sets and exactly what its module docs claim. No change. (For the app this is moot —
pinning ignores lifetime entirely.)

### Confirmed unchanged

The dio ordering flaw is real in current source (body via `addStream` ~L130, `close()` L147,
`validateCertificate` L169–182 — line numbers moved, ordering did not). Play requires
`isMonitoringTool=child_monitoring` in *every* version code across *all* tracks. iOS local-network
permission is a separate, unavoidable gate.

### Newly found, not in the doc

Play's monitoring policy also requires a persistent notification and a unique identifying icon "at
all times when the app is running" — which reads as binding the monitored device's agent, not a
viewer on the parent's phone. Same ambiguity the doc already flagged; comply where cheap.

---

## 3. Server-side contract (verified in-tree at `849dc05`)

| Fact | Location |
|---|---|
| `pair_url` → `https://{host}:{port}/p/{token}`; sole call site | `src/pairing.rs:156`, `src/install.rs:292` |
| Token: 16 chars, 15-min TTL, **single-use**, only SHA-256 stored | `src/pairing.rs:31`, `:34`, `:96` |
| `fingerprint(der)` = SHA-256, `AB:CD:` uppercase hex | `src/cert.rs:133-141` (private) |
| `read_fingerprint(path)` — public, same format | `src/cert.rs:119` |
| `generate()` makes a **new key and cert** (so SPKI pinning gains nothing over leaf-DER) | `src/cert.rs:41` |
| **`install` usually does NOT reissue** — it reuses while `cert_sans == reachable_hosts()`, reissuing only on `--new-cert` or an address change ‡ | `src/install.rs` grep `let reuse =` |
| Cookie `hh_session`: Secure, HttpOnly, SameSite=Strict, 30-day sliding | `src/server.rs:57-61` |
| Session expiry refreshed at most every 5 days | `src/auth.rs:509` |
| **`require_same_origin` fails open when `Sec-Fetch-Site` is absent** | `src/security.rs:93-99` |
| `require_lan_peer` gates off-LAN before any auth work | `src/server.rs` (outer layer) |
| Exactly 24 `/api` method+path pairs | `src/server.rs:63-90` |
| `GET /session` — **unauthenticated**, returns `{authenticated, version}` | `src/auth.rs:493-501` |
| `GET /api/time-requests` → `Vec<PendingRequest>{id,ts,minutes,reason}`, max 5 | `src/api.rs` grep `fn list_time_requests`, `src/timereq.rs:25,31` |
| Approve/deny are server-side idempotent under a mutex | `src/timereq.rs:43-49` |

‡ **Corrected after the fact.** Both marked claims were wrong in this document as originally
written, and were caught while building Phase 2: a deliberate certificate-rotation test produced an
identical fingerprint, because `install` had reused the cert. They are corrected here rather than
left for a future session to re-derive — the second one especially, since copy that leads with a
reassuring cause is worse than no guidance at all. §3's line numbers were verified at nestwatch
`5b1b8d4` and Phase 1 has since moved `src/install.rs`; grep the symbol.

### Endpoints the app uses

```
GET  /session                            unauth, LAN-gated → {authenticated, version}
GET  /p/{token}                          redeem pairing token (302 EITHER WAY — see trap 2)
POST /login                              password login
GET  /api/time-requests                  → [{id, ts, minutes, reason}], max 5
POST /api/time-requests/{id}/approve
POST /api/time-requests/{id}/deny
GET  /api/usage/today                    → today's summary (src/rules.rs:410 today_summary)
GET  /api/screenshot?tier=preview        JPEG — tier is MANDATORY, see trap 4
```

Everything else — rules, routines, curfew, audit, processes, shutdown, lock, time-codes, password —
**stays in the browser**.

### Four traps for a non-browser client

**1. `require_same_origin` fails open, and the app depends on it.** `is_same_origin` returns `true`
for `site: None`, which is the only reason a Dart client — sending no fetch-metadata headers — is
admitted at all. Nothing currently records that. Tightening `None` to reject would break the app
silently. Phase 1 adds a test naming this.

**2. `auth::pair` returns the same response for success and failure.** Both paths end at
`Redirect::to("/")` (`src/auth.rs:437`, `:463`, `:473`) — deliberately, so a spent or guessed token is
not an oracle. The client **cannot** learn whether pairing worked from the status code; it must
follow up with `GET /session` and read `authenticated`.

**3. The pairing token is single-use, and the printed instruction spends it.** `install` prints "Scan
this with your phone's camera — it opens the dashboard, signed in." A camera scan opens the *browser*
and redeems the token. A parent cannot scan the same QR with both. Nor can the QR ever deep-link into
the app: `https://192.168.1.42:8443/…` is an IP, and universal links/App Links require a verifiable
domain — so the app must always scan with its own camera view.

**4. `?tier=` defaults to `Full`.** `ShotTier::from_arg` is `Some("preview") => Preview, _ => Full`
(`src/control/mod.rs`, grep `fn from_arg`). An app that forgets the parameter silently gets
native-resolution frames — the expensive tier, and the one audited one-for-one as a deliberate human
act, so it also pollutes the security log. This is the "20 MB a frame" cost recent work removed,
re-introduced by omission.

---

## 4. Phase 1 — Fingerprint into the pairing QR (nestwatch repo)

Small, isolated, testable here, and what makes verified-first-use possible instead of
trust-on-first-use.

**Change.** Append the fingerprint as a URL **fragment** — never sent to the server, ignored by the
browser flow that exists today:

```
https://192.168.1.42:8443/p/<token>#fp=AB:CD:…
```

- `src/pairing.rs:156` — `pair_url` takes a fourth `fingerprint: &str` and appends `#fp={fingerprint}`.
  Keep the existing `AB:CD:` uppercase-hex format rather than inventing a compact one: it is what
  `nestwatch fingerprint` prints and what a parent compares by eye, one format is one test, and
  uppercase hex with colons stays inside QR alphanumeric mode where lowercase would not. Cost is a
  denser QR — verify it still renders legibly on a console at the `reachable_hosts()` worst case.
- `src/install.rs:292` — the one call site, inside `print_access_block`. Source it from the
  already-public `cert::read_fingerprint(&config::data_paths().cert)`; no new cert API needed. On
  `Err`, emit the URL without the fragment rather than failing — `print_access_block`'s own docstring
  says nothing here is worth failing an install over.

**Tests** (`src/pairing.rs` has 7 today):
1. `pair_url` embeds the fragment, and the pre-fragment prefix is byte-identical to today's output.
2. A fragment-bearing URL still round-trips through `redeem` — the server never sees `#fp=`.
3. `qr_code()` returns `Some` at a realistic worst-case host length with the fragment attached.
4. In `tests/origin.rs`: assert `is_same_origin(None, …) == true` for the POST methods the client
   uses, named so its purpose is unmissable.

**Docs.** Fold the corrections in §2 into `docs/MOBILE-APP.md` and move the fingerprint item out of
"if it gets built" — matching the house habit of recording *why* a deferred thing stopped being
deferred. CHANGELOG entry in the existing prose voice.

---

## 5. Phase 2 — Android client (`nestwatch-mobile`)

**Stack, chosen to keep the socket audit trivially answerable:** Flutter stable; `package:http` over
an explicit `dart:io` `HttpClient`; **no dio** (its documented pinning recipe is the vulnerability
above, and dropping it removes a dependency that manages its own adapter); `flutter_secure_storage`;
`mobile_scanner`.

### Pinning core

The comparison must happen *inside* `badCertificateCallback`, which runs during the handshake, and
`withTrustedRoots: false` is load-bearing: the callback only fires when a certificate *fails* to
authenticate, so leaving the default trust store in place silently admits anyone holding a
publicly-trusted certificate for that address.

```dart
HttpClient pinned(List<int> pinnedDerSha256) {
  final c = HttpClient(context: SecurityContext(withTrustedRoots: false));
  c.badCertificateCallback = (cert, host, port) =>
      _constantTimeEquals(sha256.convert(cert.der).bytes, pinnedDerSha256);
  return c;
}
```

Install as `HttpOverrides.global` in `main()` before `runApp()`. `cert.der` is the same bytes
`src/cert.rs:134` hashes.

A consequence worth selling: because the pin replaces hostname verification entirely, **the app is
immune to the SAN/DHCP problem that breaks the browser today**. The cert bakes in IP addresses at
install time (`src/cert.rs:37-39`), so a lease change makes Safari error out — and is invisible to a
pinned client.

### Pairing state machine

Designed around traps 2–4.

1. Scan QR in-app → parse `#fp=`. **No fragment** (older server) → fall back to trust-on-first-use,
   showing the fingerprint for manual comparison against `nestwatch fingerprint`, and say plainly
   that this first connection is unverified.
2. Pin, then `GET /session` — unauthenticated and LAN-gated, so it doubles as the pin probe and gives
   `version` for compatibility checks before anything secret is sent.
3. Attempt `GET /p/{token}`; ignore the redirect; re-check `GET /session`. `authenticated: true` →
   store the cookie. `false` → the token was already spent (most likely by a camera scan) or expired;
   **fall back to password login** rather than reporting failure.
4. Persist the cookie in secure storage. Dart's `HttpClient` already keeps an in-process cookie jar
   across requests to the same server, so persistence is only needed across app launches.

The 30-day sliding expiry means a regularly-used app never re-authenticates. A `401` from `/api/*`
means the session lapsed — re-prompt for the password, do not re-pair.

On **pin mismatch**, do not hand the parent a reassuring explanation first. ‡ Re-running `install`
is *not* a routine cause: it reuses the existing certificate while `cert_sans` still covers the
reachable addresses, reissuing only on `--new-cert` or an address change. nestwatch does that
deliberately, and says why — reissuing "makes EVERY paired phone and laptop show the 'not trusted'
warning again … trains the parent to click through warnings without looking — the exact habit the
fingerprint check depends on them not having."

So the innocent explanations are narrow and specific: the parent ran `--new-cert`, or the PC's
address moved. Everything else is worth alarm. Name those two, say plainly that nothing else should
change a certificate, and send them to the PC to run `nestwatch fingerprint` rather than to a
re-scan. Only the parent can tell the cases apart, and the copy must not tilt them toward the
comfortable one.

### Screens — three, and only three

Pending time requests with approve/deny; today's usage; the screenshot
(`?tier=preview`, **always explicit**). Match the dashboard's cadence — 60s for data, 5s for live
frames, stop both when not visible (grep `_pollMs` / `_refreshMs` in `assets/app.js`; they are
60000 and 5000). The pending list is capped at 5 server-side, so it never paginates. Approve is
idempotent under a server mutex — a comment at `src/timereq.rs:46` records six concurrent approvals
double-granting minutes *on a phone* — but still debounce the button.

Rules, routines, curfew and the audit log stay in the browser: configuration, done rarely, and each
one added is a second interface to keep in step with 24 routes forever.

### Notifications — revised

A `dataSync` service polling around the clock is the wrong shape: Android 15 caps it at **6h per 24h
shared across the app's services**, so it is deaf three quarters of the day, and Google documents
`dataSync` as heading for deprecation with WorkManager as the replacement. Two tiers:

- **Baseline — WorkManager periodic.** 15-minute floor (silently clamped below that), no 6h cap, no
  persistent notification, no Play foreground-service declaration. Honest promise: *"you'll hear
  about a request within about fifteen minutes."*
- **Opt-in "watch now" — a `dataSync` foreground service**, started by the parent when actively
  waiting. Polls at 60s, auto-stops well inside the budget, implements `Service.onTimeout()` →
  `stopSelf()` **from the start** rather than after the first `RemoteServiceException`. Its
  persistent notification also satisfies Play's monitoring-app notification requirement for free.

Both need `POST_NOTIFICATIONS` (Android 13+). The FGS tier additionally needs the manifest type, its
matching `FOREGROUND_SERVICE_DATA_SYNC` permission, **and** a Play Console declaration — updates are
rejected for omitting it.

### Store paperwork from day one

`<meta-data android:name="isMonitoringTool" android:value="child_monitoring" />` in every version code
across every track — apps are rejected specifically for omitting it. Never market for spouses or
employees. Keep "spy", "stealth", "hidden" out of the listing. Privacy policy naming screenshots of
the child's desktop as that child's personal data.

---

## 6. Verification

**Phase 1:** `cargo test`, plus `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`,
`cargo deny check`. Then on a real machine: the printed QR must both scan with a phone camera *and*
still land the browser at a signed-in dashboard — the fragment must be inert in the existing flow,
which is the whole reason for choosing a fragment. Compare the emitted `#fp=` against
`nestwatch fingerprint`.

**Phase 2:** against a live instance (`nestwatch run` with `NESTWATCH_DATA_DIR` set), not a mock.

- **Prove the pin by failure, not by success.** Point the app at a server presenting a different
  certificate and confirm the handshake is refused **before any request body is sent** — capture on
  the wire. That is precisely the property dio's example loses, and a test that only checks "wrong
  cert ⇒ error" would pass against the broken implementation too.
- Re-run `install` and confirm the app refuses the new certificate and prompts to re-pair, rather
  than silently trusting it.
- Confirm a camera-spent token degrades to the password prompt instead of a dead end.
- Confirm `?tier=preview` on the wire and no `screenshot_taken` entries accumulating in the audit log
  from live viewing.
- Let the "watch now" service run past 6h and confirm `onTimeout()` fires and stops cleanly.
- Test with a VPN active on the phone: `require_lan_peer` will 403, and the message should say so
  rather than "server unreachable."

---

## 7. Deferred, with reasons

- **iOS** until Android works. The ATS-vs-`dart:io` inference is sound but still not documented in
  Apple's or Flutter's words; test on **real hardware** — the Simulator does not implement
  local-network privacy at all. iOS also needs `NSLocalNetworkUsageDescription`, and a local-network
  call attempted in the background while permission is undetermined is denied silently without even
  recording the denial.
- **Away-from-home notification** is not deferred, it is impossible: push requires the *server* to
  reach Apple's or Google's services, which this design forbids. `docs/REMOTE-ACCESS.md`'s VPN route
  is the answer.
- **Tauri v2** considered and rejected. Rust core plus webview would reuse the Alpine dashboard and
  the serde types, and its mobile APIs are stable — but the reuse argument collapses against this
  plan's own scoping: three screens with configuration left in the browser leaves little dashboard to
  reuse, while the webview's Apple 4.2 exposure and a `fetch()`→`invoke()` refactor of `web/` remain.
- **Long-polling `GET /api/time-requests?wait=25`** would give the "watch now" tier near-instant
  delivery at *fewer* requests than 60s polling. Attractive, but it changes server behaviour for a
  client that does not exist yet. Revisit once the app is real.
- **mDNS.** The QR already carries address, port and token. Once pinning exists, a local-range sweep
  for whichever host presents the pinned certificate solves lease changes — unspoofable by
  construction, no multicast, no iOS local-network prompt for discovery.

---

## 8. Unrelated findings, unclaimed

Surfaced across three concurrent sessions and declined by every one of them as out of scope. Not
part of this plan; recorded here so they do not fall into the gap between sessions that each
correctly decided the work was not theirs.

1. **`web/scripts/strip-comments.mjs:145`** — the ratio guard is ~8–12 added comment lines from
   failing the whole `npm run build` on both CI OSes (the exact figure varies with indent depth,
   because `stripJs` copies leading whitespace into the output). Its message asserts "the scanner
   mis-parsed it", which is false for first-party files — and the `alpine.min.js` case that motivated
   the guard can no longer reach it, since `ours()` skips `.min.js` before the scan. Better fix:
   keep the throw, swap the trigger to `quote != null` at end of parse, which is an exact mis-parse
   signal rather than a proxy.
2. **`src/doctor.rs`** — never consults `preflight::check_windows_build`. Verified by call graph:
   `check_windows_build` is called only from `preflight::gather`, which is called only from
   `src/install.rs:100,118`; `doctor.rs` contains the string "preflight" exactly once, in a doc
   comment, never as a call. So on Windows < build 18362 `install` warns, but `doctor` — the tool the
   README points at for "what's wrong?" — reports green while every screenshot fails. The failure
   mode is the bad kind: the diagnostic contradicts the symptom, sending the parent elsewhere. Fix
   needs `os_build` to become `pub(crate)`. (Symbols, not lines — `preflight.rs` is being edited.)
3. **`src/screentime.rs`** — three inlined copies of the minutes/name ranking comparator.
4. **`src/rules.rs`** — a second `session_stop` emission site.

Items 3 and 4 may be correctness rather than cleanliness, which puts them in a code-review queue
rather than a simplify pass. Items 1 and 2 are the ones likely to bite someone.

---

## 9. Starting the new repo

### Phase 1 and Phase 2 are independent — start with Phase 2

They live in different repos and neither blocks the other. **The app can be built and tested against
nestwatch exactly as it is today**, because the pairing state machine (§5) already handles a server
whose QR carries no `#fp=` fragment: it falls back to trust-on-first-use and shows the fingerprint
for manual comparison against `nestwatch fingerprint`.

Phase 1 upgrades that first connection from trust-on-*first-use* to *verified* first use. It is a
half-day change in the nestwatch repo and can land any time — before, during or after the app.

Do Phase 1 in a session rooted at `/Users/emrec/Projects/playground/nestwatch`. Do Phase 2 in a
session rooted at the new folder. Do not try to do both from one working directory.

### Scaffolding

**Prerequisites — verified on this machine 2026-08-26**, not assumed:

| | |
|---|---|
| Flutter | `3.44.6` stable, Dart `3.12.2` — at `/Users/emrec/development/flutter` |
| Android toolchain | ✓ Android SDK `36.0.0` — ready to build |
| Connected devices | 3 available |
| iOS Simulator | not installed — **irrelevant**, Android-first, and §7 says the Simulator is useless for this project anyway (no local-network privacy implementation) |

⚠️ `flutter doctor` warns that `dart` on `PATH` resolves to Homebrew's copy
(`/opt/homebrew/bin/dart`) rather than the Flutter SDK's. Same version today, but they can drift.
Put `/Users/emrec/development/flutter/bin` at the front of `PATH` before starting.

This document already lives at
`/Users/emrec/Projects/playground/nestwatch-mobile/docs/PLAN.md`. Scaffold **around** it —
`flutter create` populates a directory that already has files in it:

```bash
export PATH="/Users/emrec/development/flutter/bin:$PATH"
cd /Users/emrec/Projects/playground/nestwatch-mobile
flutter create --org com.nestwatch --project-name nestwatch_mobile --platforms=android .
git init && git add -A && git commit -m "Flutter scaffold and the plan it is built from"
```

The trailing `.` scaffolds into the current directory rather than creating a nested one. **This
exact command was run in a scratch directory to confirm it**: it produced `android/`, `lib/`,
`test/`, `pubspec.yaml`, created no `ios/`, and left a pre-existing `docs/PLAN.md` untouched.

⚠️ **Decide the `applicationId` before the first Play upload — it can never be changed after.**
The command above yields `applicationId = "com.nestwatch.nestwatch_mobile"` (org + project name,
in `android/app/build.gradle.kts`). That is legal but it stutters, and underscores are unusual in
Android package names. If you want `com.nestwatch.mobile` — or something under the GitHub org,
`com.emrecdr.nestwatch` — edit `applicationId` and `namespace` in `android/app/build.gradle.kts`
straight after scaffolding. The Dart package name (`nestwatch_mobile`, in `pubspec.yaml`) is a
separate thing, is correct as-is, and should keep its underscore.

Android only to begin with — adding iOS later is `flutter create --platforms=ios .` and does not
require restructuring. Resolve dependency versions at `pub add` time rather than pinning from this
document; what matters is not the version but the constraint below.

Dependencies: `http`, `crypto`, `flutter_secure_storage`, `mobile_scanner`, `workmanager`.
**Explicitly not `dio`** — see §2.

> **The one dependency rule.** No package may bypass `dart:io`'s `HttpClient`, because
> `HttpOverrides.global` is what pins every request in the process (§2). Adding `cupertino_http`,
> `cronet_http`, or anything that opens a raw `SecureSocket` silently un-pins that dependency's
> traffic. Audit on every `pub add`, not once at the start.

### First milestone: a walking skeleton, pin first

Build in this order. Each step is verifiable against a live server before the next begins.

1. `nestwatch run` on the dev box (§0), `nestwatch fingerprint` for the expected value.
2. Pinned `HttpClient` + `HttpOverrides.global` in `main()`. Hit `GET /session` and print
   `{authenticated, version}`. **Then prove the pin by failure** — point it at a server with a
   different certificate and confirm refusal before any body is sent (§6).
3. QR scan → parse `#fp=` (absent today) → the TOFU fallback path.
4. Password login → cookie in secure storage → survives app restart.
5. Only then the three screens.

Step 2 is the whole project's risk. If pinning works and refuses correctly, everything after it is
ordinary Flutter.

### The prompt for the new session

Run this from `/Users/emrec/Projects/playground/nestwatch-mobile`. Every path in it is absolute, so
it does not matter what the session's working directory turns out to be.

```
Read /Users/emrec/Projects/playground/nestwatch-mobile/docs/PLAN.md in full before
doing anything — it is a validated implementation plan for this project, written by
a previous session, and it contains verified facts about the server this app talks
to that you will not be able to re-derive cheaply.

This repo is empty apart from that document, so scaffold it first using the exact
flutter create command in §9, then build Phase 2 (§5): the Android client.

Follow the walking skeleton in §9 and STOP after step 2 — the pinned HttpClient,
proven by failure — so I can watch the pin refuse a wrong certificate before we
build anything on top of it. Do not continue to the screens without checking in.

The server lives at /Users/emrec/Projects/playground/nestwatch. Do not modify it.
§0 has the commands to run a dev instance to develop against.

Three things in the plan are load-bearing and easy to get wrong; §3 explains each:
  - withTrustedRoots: false, and the comparison inside badCertificateCallback
  - GET /api/screenshot needs ?tier=preview explicitly, always
  - GET /p/{token} returns 302 whether pairing succeeded or failed

The plan's line-number citations were verified at nestwatch HEAD 5b1b8d4 on a branch
that moves fast. Grep for the named symbol rather than trusting any line number, and
tell me if a cited fact no longer holds.
```
