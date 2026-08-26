# nestwatch-mobile

Android client for [nestwatch](https://github.com/emrecdr/nestwatch) — a LAN-only parental
dashboard served by a Rust binary on the monitored PC. Nothing leaves the house, so this app
talks to that PC directly over HTTPS with a **pinned certificate** and no cloud in between.

The implementation plan is [`docs/PLAN.md`](docs/PLAN.md). It is validated, and it is the
source of truth for the server contract — read it before changing anything here.

## Status

Walking skeleton (PLAN §9), **steps 2–3 of 5**:

- **step 2** — the pinned `HttpClient`, proven by failure.
- **step 3** — QR scan, `#fp=` parsing, and the trust-on-first-use fallback.
- **step 4** — token redemption, password login, and a session that survives a restart.
- **step 5** — three screens: time requests, today's usage, the screenshot.

The walking skeleton is complete. Rules, routines, curfew and the audit log stay in the
browser, deliberately — configuration is done rarely, and each screen added here is a
second interface to keep in step with 24 routes forever.

### Two ways to end up pinned

| | how the fingerprint is learned | worth |
|---|---|---|
| **Verified** | the QR carried `#fp=` (PLAN Phase 1) | checked against a value that never crossed the network |
| **Trust on first use** | read off the server, confirmed by the parent against `nestwatch fingerprint` | only as good as that comparison |

No nestwatch has shipped `#fp=` yet, so every pairing today takes the second route. The
app records which one happened (`PinProvenance`) and keeps saying so — a warning shown
once at pairing and then forgotten would make the weaker trust indistinguishable from the
stronger one forever after.

## The one dependency rule

No package may bypass `dart:io`'s `HttpClient`. `HttpOverrides.global` is what pins every
request in the process; `cupertino_http`, `cronet_http`, or anything opening a raw
`SecureSocket` hands its traffic to a stack this override never sees. **Audit on every
`pub add`, not once at the start:**

```bash
grep -rln 'cupertino_http\|cronet_http\|SecureSocket\|HttpOverrides.runZoned' \
  ~/.pub-cache/hosted/pub.dev/<each-resolved-package>/lib
```

`http.runWithClient` is a false positive — it swaps `package:http`'s `Client`, and `IOClient`
still bottoms out at the `HttpClient()` factory that consults the override.

## Proving the pin

Not "wrong cert ⇒ error" — that passes against an implementation that checks the certificate
*after* streaming the request body, which is the flaw in dio's published recipe. The proof has
to show **nothing crossed the wire**.

Stand up two nestwatch instances with different certificates, plus a TLS listener that counts
application bytes:

```bash
# real server
cd ../nestwatch
NESTWATCH_DATA_DIR=/tmp/nestwatch-dev NESTWATCH_PASSWORD=dev-password-4-testing \
  cargo run -- install --port 8443
NESTWATCH_DATA_DIR=/tmp/nestwatch-dev cargo run -- run &

# impostor: same software, same SANs, different certificate
NESTWATCH_DATA_DIR=/tmp/nestwatch-impostor NESTWATCH_PASSWORD=impostor-password-4-testing \
  cargo run -- install --port 8444
NESTWATCH_DATA_DIR=/tmp/nestwatch-impostor cargo run -- run &

# byte-counting sink, presenting the impostor's certificate
cd ../nestwatch-mobile
python3 tool/wire_sink.py /tmp/nestwatch-impostor/cert.pem \
  /tmp/nestwatch-impostor/key.pem 9443 > /tmp/nestwatch-sink.log &

dart run tool/prove_pin.dart \
  --pin "$(cd ../nestwatch && NESTWATCH_DATA_DIR=/tmp/nestwatch-dev cargo run -q -- fingerprint | tail -1)" \
  --real 8443 --impostor 8444 --sink 9443
```

Four checks, and check 4 is the one that keeps it honest: it re-runs the same rig with the
sink's own certificate pinned and requires the body to arrive. Without it, a broken rig that
reports "no bytes" for any reason would pass check 3 against any implementation.

That is not hypothetical — it has caught a false pass twice. Most recently a leftover sink
from an earlier run still owned port 9443, the new one died on bind, and check 3 passed
against an empty log. `prove_pin.dart` now refuses to start unless the sink's log says it
is listening; if it stops, run `lsof -ti :9443 | xargs kill`.

Step 3 has its own live proof, covering both routes and — the check that matters — that a
QR naming the *wrong* certificate is refused rather than quietly downgraded to a
trust-on-first-use prompt, which would make Phase 1's fingerprint decorative:

```bash
dart run tool/prove_tofu.dart --real 8443 --impostor 8444 --pin "$FINGERPRINT"
```

Step 4 covers redemption, login and restart survival:

```bash
# --token is optional; mint one first to cover the redemption checks
cd ../nestwatch && NESTWATCH_DATA_DIR=/tmp/nestwatch-dev cargo run -- pair

dart run tool/prove_login.dart --pin "$FINGERPRINT" --password "$PW" [--token TOK]
```

Step 5 covers the three screens' data paths:

```bash
dart run tool/prove_screens.dart --pin "$FINGERPRINT" --password "$PW"
```

It checks the preview tier **by JPEG dimensions**, because the wrong tier also returns 200
with a valid image — size is the only thing that can tell them apart.

That harness is deliberately re-runnable. A pairing token is single-use with a 15-minute
TTL, and a deliberate wrong-password check spends one of the five attempts before
nestwatch locks an IP out for a minute — so `--token` is optional and skips *aloud* when
absent or spent, the wrong-password check runs last, and preflight signs in **correctly**
(which clears the limiter, since `record_success` resets it). An earlier version required
a fresh token and probed with a wrong password, and its second run reported ten failures
that were all artifacts of itself.

Both harnesses run under plain `dart run`, with no emulator. That is deliberate: the
pairing state machine deposits no Flutter imports, so the part of this app that decides
what to trust stays testable against a live server on every change. `ServerIdentityStore`
is abstract for the same reason — the Keystore-backed implementation lives apart, in
`secure_identity_store.dart`.

## The three screens

| screen | endpoint | cadence |
|---|---|---|
| Requests | `GET /api/time-requests`, `POST …/approve`, `…/deny` | 60 s |
| Today | `GET /api/usage/today` | 60 s |
| Screen | `GET /api/screenshot?tier=preview` | 5 s, **off by default** |

60 s and 5 s mirror `_pollMs` and `_refreshMs` in nestwatch `assets/app.js`. Every screen
stops polling when its tab is not showing **and** when the app is backgrounded — a phone
in a pocket must not keep asking for frames, not least because each one writes to that
PC's audit log.

Three things that look like details and are not:

**`?tier=preview` has no error path.** `ShotTier::from_arg` is
`Some("preview") => Preview, _ => Full`, so omitting the parameter returns a perfectly
valid JPEG at the expensive tier. Measured: 1280×720 / 62,795 bytes without it against
960×540 / 21,985 with it — and on a real 4K desktop that gap is the "20 MB a frame" recent
work removed. Worse, a Full capture writes `screenshot_taken` to the audit log one-for-one,
where previews coalesce into one `live_view` entry, "because a per-frame line evicts the
entire security history in about 57 hours of live viewing". The tier is therefore hard-coded
inside `screenshotPreview()`, with no parameter and no Full equivalent: an argument with a
default is exactly how the wrong tier gets sent.

**A second approve returns 400, not 200.** The mutex in `TimeRequests::resolve` makes the
*grant* happen exactly once — it does not make the second call succeed. So `approve` returns
`bool` for "was this the call that acted", and a 400 refreshes the list instead of showing
a parent an error. The button is debounced too; nestwatch's own comment records why the gate
exists: "six concurrent approvals of one request all returned `Some` — so a parent
double-tapping Approve on a phone granted the minutes twice".

**`used_mins: 0` is ambiguous.** It means both "nobody used the PC" and "nothing was
watching". `enforcer_age_secs` and `focus_missing` are the only things that separate them,
and both carry a comment in `rules.rs` saying so — "rendering silence as zero is the failure
this codebase has already fixed twice". Both are surfaced *above* the numbers they qualify,
and a missing heartbeat reads as the warning, never as health.

`Image.network` is deliberately unused for the screenshot despite PLAN §2 proving it is
pinned: `ImageCache` keys on the URL, this URL never changes, and a 5-second refresh would
redisplay one cached frame forever. Fetching bytes through the pinned client and rendering
`Image.memory` also avoids threading the session cookie in as a raw header.

## Unit tests

```bash
flutter test        # fingerprint, QR parsing, mismatch classification, cookie handling
```

## A correction to PLAN §5

The plan states that *"Dart's `HttpClient` already keeps an in-process cookie jar across
requests to the same server, so persistence is only needed across app launches."*

**It does not.** Measured against nestwatch 0.3.0: a `POST /login` returning
`200 {"ok":true}` with a `Set-Cookie: hh_session=…` is followed, *on the very same client
instance*, by a `GET /session` answering `{"authenticated":false}`. `dart:io` exposes
`response.cookies` and `request.cookies` and stores nothing in between — there is no jar.

So `NestwatchClient` keeps one and applies it to every request, not merely at launch.
Three things fell out of the same measurement: attaching by hand works; a brand-new
client accepts the same cookie, so it is not bound to client identity; and `name` +
`value` alone suffice, because `Secure`/`HttpOnly`/`Max-Age` are server→client
instructions that are never echoed back.

## Two secrets, two reasons

| | stored for | losing it costs |
|---|---|---|
| certificate fingerprint | **integrity** — a rewritten pin defeats pinning silently and permanently | a re-pair |
| `hh_session` cookie | **confidentiality** — a bearer token for the whole dashboard, 30 idle days | a password prompt |

Both live in `flutter_secure_storage` under separate keys, so signing out cannot un-pair
and re-pairing can drop a session without disturbing the pin it just established.

## Android notes

- `compileSdk = 37`, above Flutter's default of 36, because `flutter_secure_storage` 11
  requires it. `minSdk` stays at Flutter's 24, which clears both plugin floors.
- `INTERNET` is declared in the **main** manifest. Flutter's template puts it only in
  `debug`/`profile`, so a release build would ship with no network access.
- The MLKit barcode model is **bundled**, not downloaded — see `android/gradle.properties`
  for why the usual size-saving advice is wrong here.
- `mobile_scanner` still applies the Kotlin Gradle Plugin directly, which Flutter warns
  will stop working in a future release. Not breaking today; worth watching on upgrade.

## Layout

```
lib/src/pinning/fingerprint.dart            AB:CD: parsing, constant-time compare
lib/src/pinning/pinned_http_overrides.dart  the pin, and why withTrustedRoots: false
lib/src/pinning/pin_mismatch_message.dart   explaining a refusal to a parent
lib/main.dart                               step-2 probe screen
tool/prove_pin.dart                         the proof-by-failure harness
tool/wire_sink.py                           TLS listener that counts application bytes
```
