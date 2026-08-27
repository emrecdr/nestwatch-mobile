# nestwatch-mobile

Android client for [nestwatch](https://github.com/emrecdr/nestwatch) — a LAN-only parental
dashboard served by a Rust binary on the monitored PC. Nothing leaves the house, so this app
talks to that PC directly over HTTPS with a **pinned certificate** and no cloud in between.

The implementation plan is [`docs/PLAN.md`](docs/PLAN.md), what is still open is
[`docs/OPEN-FINDINGS.md`](docs/OPEN-FINDINGS.md), and the hardening review that fed it is
[`docs/HARDENING.md`](docs/HARDENING.md). The plan is validated, and it is the source of
truth for the server contract — read it before changing anything here.

## Status

Walking skeleton (PLAN §9), **complete** — each step proven against a live server before
the next began, by the harness named beside it:

- **step 2** — the pinned `HttpClient`, proven by failure. `prove_pin.dart`
- **step 3** — QR scan, `#fp=` parsing, and the trust-on-first-use fallback. `prove_tofu.dart`
- **step 4** — token redemption, password login, and a session that survives a restart.
  `prove_login.dart`
- **step 5** — time requests, today's usage, the screenshot, and [a fourth screen the plan
  did not ask for](#the-four-screens). `prove_screens.dart`, `prove_timecodes.dart`
- **notifications** — both tiers: a WorkManager periodic poll, and an opt-in "watch now"
  `dataSync` foreground service. `prove_background.dart`

Verified first use — the QR carrying `#fp=` — needed PLAN Phase 1, which lives in the
nestwatch repo and landed there; `prove_phase1.dart` checks it against that server's own
`pair_url` output rather than a fragment this side synthesised.

What remains is all outside this repo: a Play Console `dataSync` declaration, a privacy
policy, a release signing keystore, the QR camera path (needs hardware), and
`Service.onTimeout` (needs API 35 and six real background hours).

Rules, routines, curfew and the audit log stay in the browser, deliberately —
configuration is done rarely, and each screen added here is a second interface to keep in
step with 24 routes forever.

### Two ways to end up pinned

| | how the fingerprint is learned | worth |
|---|---|---|
| **Verified** | the QR carried `#fp=` (PLAN Phase 1) | checked against a value that never crossed the network |
| **Trust on first use** | read off the server, confirmed by the parent against `nestwatch fingerprint` | only as good as that comparison |

**Both routes now work against a real server.** nestwatch `e7b90b7` emits `#fp=` in the
QR (and deliberately *not* in the printed URL below it — only a scanning client can use a
fingerprint, and printing it wraps an 80-column console). `tool/prove_phase1.dart` runs
the verified route end to end against that server's own `pair_url` output.

The app records which route happened (`PinProvenance`) and keeps saying so — a warning
shown once at pairing and then forgotten would make the weaker trust indistinguishable
from the stronger one forever after.

## The one dependency rule

No package may bypass `dart:io`'s `HttpClient`. `HttpOverrides.global` is what pins every
request in the process; `cupertino_http`, `cronet_http`, or anything opening a raw socket
hands its traffic to a stack this override never sees. **Audit on every `pub add`, not
once at the start:**

```bash
tool/audit_deps.sh     # 0 clean · 1 something bypasses · 2 the audit could not read
```

This replaced a one-line `grep` that had **never worked**. It looked for `SecureSocket`,
which matches nothing in this pub-cache and nothing in this repo — so it had never once
produced a hit, and a clean result was indistinguishable from a broken pattern. It was
written from a guess about what an offending package would contain and never confirmed
against a known positive.

So the script refuses to report a clean tree until it has proved it can read one: a
control pattern that every Dart package contains must match, and a zero there exits **2**
rather than 0. All three outcomes were watched to happen — a planted package that opens a
`SecureSocket` is reported and exits 1, an unreadable tree exits 2, and the real tree
exits 0. `PUB_CACHE_LIB` and `PUBSPEC_LOCK` exist so that stays re-runnable.

Two packages match today and both are listed with the reason they do not count — `dbus`
(Unix sockets for Linux D-Bus, reached only by `flutter_secure_storage`'s Linux
implementation, never compiled into an Android build) and `vm_service` (dev-time
transitive of `flutter_test`, not shipped). An allowlist that stops matching is reported
as `STALE` rather than carried, because an entry nobody re-justifies is how an audit
quietly narrows to nothing.

**This app has no HTTP package at all.** PLAN §5 specifies "`package:http` over an
explicit `dart:io` `HttpClient`" and §9 lists `http` among the dependencies; neither is
here. `NestwatchClient` calls `HttpClient` directly. That is a deviation from the plan and
a stricter reading of its own rule — the rule says nothing may bypass `HttpClient`, and
the surest way to satisfy it is to have nothing in between. `http.runWithClient` would
have been a false positive in the audit above (it swaps `package:http`'s `Client`, and
`IOClient` still bottoms out at the `HttpClient()` factory that consults the override) —
noted because the plan expects that package, and a future reader will wonder where it went.

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

The notification tier:

```bash
dart run tool/prove_background.dart --pin "$FINGERPRINT" --password "$PW"
```

Its first check asserts a *vulnerability*: that a freshly spawned isolate reports
`HttpOverrides.current == null`. If that ever starts failing, Dart changed something and
the pinning story needs re-checking — it is not a reason to celebrate.

### What was verified on a device, and what was not

Verified on an Android 13 emulator against the live server: the permission prompt; that
WorkManager schedules with the requested constraints; that the background isolate runs,
loads the pin and cookie out of the Keystore, makes a *pinned* HTTPS request and posts a
notification while the app is backgrounded; and — on a genuine 15-minute cycle, not a
forced one — that a request resolved elsewhere has its notification withdrawn on the next
poll.

Not verified on a device: that a *still-pending* request is not re-announced on the second
poll. `cmd jobscheduler run -f` cannot force a periodic WorkManager task early — it logs
`"Delaying execution ... because it is being executed before schedule"` and re-enqueues —
so a second run inside one period is not reachable from the shell. That branch is covered
headlessly by `prove_background.dart` check 3 and by `test/seen_requests_test.dart`, both
exercising the same `pollOnce`.

Verified for the watch-now tier, on the same emulator: the service starts as a genuine
foreground service (`isForeground=true`, channel `nestwatch.watching`,
`targetSdkVersion:36`); its own isolate installs the pin and polls at 60 s **while the app
is backgrounded**, posting the alert alongside the persistent indicator; and toggling it
off removes the service and withdraws that indicator, with no restart after.

Not verified for that tier: the timeout path. `Service.onTimeout` is API 35 and only fires
after six hours of background foreground-service time, which no emulator session here can
reach. That the `allowAutoRestart: false` guard prevents the restart loop rests on reading
`ForegroundService.onDestroy` — note that the clean-stop test above does *not* exercise it,
because a Dart-initiated stop skips the restart branch by way of `isCorrectlyStopped()`
instead.

Also still unverified anywhere: the QR camera path, which needs real hardware.

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

## The four screens

| screen | endpoint | cadence |
|---|---|---|
| Requests | `GET /api/time-requests`, `POST …/approve`, `…/deny` | 60 s |
| Today | `GET /api/usage/today` | 60 s |
| Screen | `GET /api/screenshot?tier=preview` | 5 s, **off by default** |
| Codes | `GET`/`POST /api/time-codes` | 60 s |

PLAN §5 said "three, and only three", keeping rules, routines and curfew in the browser as
"configuration, done rarely". Codes is a deliberate exception, and the reason is that the
test is really about *where the parent is* when they need the thing. A time code is used
**because** you are away from the browser — the parent mints one before leaving, the child
types it on the ask page, and the minutes land in that day's budget with no parent action
and no internet at redemption. §7 calls away-from-home support impossible, which holds for
*notification* but not for this: nestwatch already solved it offline (`src/timecode.rs` —
"Useful when the parent is away (leave a code) or the network is down") and the app was
simply not surfacing it.

The code is treated as a secret, because it is one: it grants screen time to whoever types
it, and nestwatch keeps it out of the audit log for that reason. Codes are hidden behind a
reveal, never rendered by `toString`, and `prove_timecodes.dart` asserts the value never
reaches the log.

Codes are **6 characters** (nestwatch `CODE_LEN`), and that length lives on the server —
this app displays codes, it never mints or validates them, so nothing here hard-codes it.
The reveal mask is `'•' * code.length` rather than a literal run of dots, which is what
made the 8 → 6 change a one-line edit to a doc comment rather than a silent rendering bug.
`prove_timecodes.dart` pins the agreed length against a live server, with a literal
instead of a constant this repo defines — asserting the app's own idea of the length
against itself would pin nothing.

Verified end to end across both halves of the system, on an emulator against a live
server: the app minted `3NRPM1`, a `POST /redeem-code` as the child would send it answered
`{"minutes":15,"ok":true}`, today's granted minutes moved 645 → 660, a second redemption
answered `{"ok":false}`, the code vanished from the app's list on refresh, and the audit
log recorded `time_code_issued` / `time_code_redeemed` without ever containing the code.

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

## Events, and why the poll stays

nestwatch 0.4.0 serves `GET /api/events` — a `text/event-stream` of bare tags,
`requests` and `usage`, plus `all` when a subscriber has fallen behind. No payload: the
tag is the whole message and the answer is to refetch through the ordinary endpoint.

PLAN §7 deferred long-polling because "it changes server behaviour for a client that does
not exist yet. Revisit once the app is real." The app is real, and the behaviour changed
anyway — for nestwatch's own dashboard.

**What it buys is latency, not fewer requests**, and an earlier draft of this section
claimed both. Worst-case wait for a new request drops from 60 s to about one. The poll
underneath is unchanged, so nothing was subtracted — a review pass caught the arithmetic:
one held connection *plus* the same sixty polls an hour is more traffic than before, not
less. Lengthening the cadence while the stream is healthy would realise the saving and is
not done here, because the backstop stops being a backstop the moment it is tuned by the
thing it is backing up.

**The 60 s poll stays underneath it.** A poller that stops is silent for one interval; a
stream that stops is silent forever and looks exactly like a house where nothing is
happening. Events make the poll arrive early; they are never the only source of truth.

Three things were read rather than assumed, because the parser turns on them:

| | |
|---|---|
| the keep-alive is the literal bytes `":\n\n"` | `Event::DEFAULT_KEEP_ALIVE` in axum 0.8.9 |
| dispatch is gated on the **data** buffer, not on an `event:` line | the SSE spec — and it is what stops that keep-alive registering as news |
| `HttpClientResponse` is a `Stream<List<int>>` | `dart:io`, which is why `utf8.decoder` binds to it |

Reconnection lives in `ServerEvents`, apart from the wire code, and backs off from one
second to a cap of thirty. Only a delivered **event** resets that backoff — a successful
*connect* would also be satisfied by a server that accepts and immediately closes, which
turns backoff into a busy loop that reports itself as healthy. A 401 is handed up rather
than retried: another connection cannot fix a lapsed session.

`isReceiving` is exposed because a screen claiming live updates it is not receiving is
worse than one that admits to polling.

## Notifications

The baseline tier from PLAN §5, and only that tier. A `dataSync` foreground service
polling round the clock is the wrong shape twice over: Android 15 caps `dataSync` at
**6 hours per 24 shared across all of an app's services**, so it is deaf three quarters of
the day, and Google documents it as heading for deprecation with WorkManager named as the
replacement.

WorkManager has a 15-minute floor — anything shorter is silently clamped — no 6-hour cap,
no persistent notification and no Play foreground-service declaration. The app's copy says
exactly that rather than implying immediacy: *"Android will not check more often than every
15 minutes for an app that is not running, so this is a heads-up rather than an alert."*

### The trap: a background isolate is not pinned

`HttpOverrides._global` is a plain `static` field (`dart-sdk/lib/_http/overrides.dart`),
and **Dart statics are per-isolate**. A WorkManager task runs in its own isolate, spawned
from `callbackDispatcher`, which never executes `main()` — so it starts with
`HttpOverrides.current == null`. The workmanager docs teach exactly that shape: their
"Manage Resources in Background Isolates" example constructs `HttpClient()` with no
overrides.

What that costs is worth stating precisely, because the obvious guess is wrong. It does
**not** silently talk to an impostor — no public CA vouches for a self-signed certificate
on a private LAN address, so an un-bootstrapped isolate cannot connect at all. The
handshake is refused and the poll quietly does nothing.

That is the trap. The symptom is "background notifications never arrive", and the fix that
symptom invites is `badCertificateCallback = (_, _, _) => true` in the background isolate —
which accepts anything, is catastrophic, and reads in a diff as making background sync
work. `openBackgroundSession()` is the only way to get a client in that isolate, and it
installs the pin before anything else.

The same rule bars writing the polling in Kotlin: native HTTP never enters `dart:io`, so it
cannot be pinned by this mechanism at all — exactly why `cronet_http` is banned.

### The opt-in "watch now" tier

A `dataSync` foreground service the parent starts when actively waiting, polling at 60 s
instead of 15 min, stopping itself after 30 minutes.

Android 15 allows `dataSync` **6 hours per 24**, shared across every one of the app's
services, counted while the app is in the background. Exceeding it calls
`Service.onTimeout(int, int)` and allows a few seconds to `stopSelf()` before throwing
`RemoteServiceException: "A foreground service of type dataSync did not stop within its
timeout"`. Our `targetSdk` is 36, so this applies.

The 30-minute session limit is chosen against the budget, not the platform maximum: at
least four sessions must fit in a day, or the first watch of the morning would leave the
evening with none. A test asserts that arithmetic.

**`allowAutoRestart: false` is load-bearing.** `flutter_foreground_task` implements both
`onTimeout` overloads correctly — but `ForegroundService.onDestroy` restarts the service
when `allowAutoRestart && !isCorrectlyStopped`, and `isCorrectlyStopped()` is true only
when the *Dart* side called `stopService()` (stored action `API_STOP`). A system timeout
leaves it at `API_START`. So on the shipped defaults: hit the 6-hour cap → `onTimeout` →
`stopSelf()` → `onDestroy` sees an "incorrect" stop → restart alarm in 5 seconds →
relaunch already over budget → timed out again. A restart loop against a system that just
said stop, reached *through* a correct `onTimeout`.

Turning auto-restart off is right for this feature anyway: watching is deliberate and
brief, and auto-restart exists for always-on trackers — the design §5 rejects.

### Permissions WorkManager brings with it

`androidx.work` merges these into the manifest whether or not you use them:

```
FOREGROUND_SERVICE
FOREGROUND_SERVICE_SHORT_SERVICE
WAKE_LOCK
RECEIVE_BOOT_COMPLETED
```

They are there because *expedited* work runs as a short foreground service on API 31+.
This app never requests expedited work — but **Play does not care who declared them**.
PLAN §5 warns that foreground-service types need a Play Console declaration and that
"updates are rejected for omitting it", and that now applies even though the foreground
service tier was deliberately not built. For a child-monitoring app an unexplained
foreground-service permission also invites extra review.

Two options, neither taken here without a decision: declare `shortService` in Play Console
at upload time, or strip it with `tools:node="remove"` since nothing requests expedited
work. Stripping a permission a library declares is the kind of thing that breaks quietly
later, so it is flagged rather than done.

### Store paperwork

`<meta-data android:name="isMonitoringTool" android:value="child_monitoring" />` is in the
main manifest from day one. Apps are rejected specifically for omitting it, and it must be
present in **every version code across every track** — including the first internal-test
upload.

## Unit tests

```bash
flutter test        # no servers needed; the run prints its own count
```

`test/pinning_socket_test.dart` stands up a real TLS server on loopback and drives the
pin through an actual handshake, asserting from the server's end that its request handler
never ran. Before it existed, `flutter test` was green while the one security property
this app exists for went unchecked by the suite — it was proven only by
`tool/prove_pin.dart`, which needs three live servers and so cannot run in CI.

## The contract with that PC

```bash
NESTWATCH_REPO=../nestwatch ./tool/check_golden.sh
```

Two repos have to agree about more than they can see of each other: the JSON shapes this
app parses, and a handful of numbers it renders in front of a parent before any request
completes — "1 to 240 minutes", "5 failures in a minute".

`test/golden/` holds files nestwatch's own serde types produced, `limits.json` among them.
They are **copies**, so `flutter test` runs on a machine that has this repo and nothing
else; the alternative is reading a sibling checkout and skipping when it is absent, and a
test that quietly stops running reports success either way. The assertions live in
`test/models_golden_test.dart` and run on every commit. This script's only job is keeping
the copies honest.

Three outcomes, and the third is the point:

| | |
|---|---|
| `same` | checked, and they agree |
| `DRIFTED` / `ORPHANED` / `MISSING HERE` | checked, and they do not — exit 1 |
| nestwatch absent | **nothing was compared** — exit 2, never silence |

That last row earned itself twice in one afternoon. The limits used to be read by grepping
nestwatch's Rust for its constants; those constants were then given names — an improvement
on that side — and the reader looking for the old shape found nothing. It said *"Nothing
was compared. This is not agreement."* rather than printing four quiet `same` lines, which
is the only reason either session noticed. The grep is gone; `limits.json` replaced it.

### The other file the two repos share

`docs/OPEN-FINDINGS.md` exists on both sides, with the same rules, and they cite each other
as `repo#ID`. `tool/check_findings.sh` follows those references in both directions.

It is worth having for one reason. Both files **delete** an entry when it is fixed — so a
reference that resolved yesterday and dangles today is not sloppiness, it is the other side
having shipped something, and for an entry that was *waiting* on it that is exactly when the
wait ends. `M6` waits on `nestwatch#O72`; the way this repo finds out that day came is the
`O72` heading vanishing.

So the script reports a dangling reference as likely good news rather than as a failure, and
its third outcome is the usual one: no sibling checkout, nothing compared, exit 2.

```bash
tool/check_findings.sh    # 0 all resolve · 1 something dangles · 2 could not look
```

`MISSING HERE` fired for real too: it is what reported that nestwatch had begun producing
`limits.json` before this app consumed it.

### And the version those files came from

`GET /session` returns `{authenticated, version}`, and PLAN §5 probes it partly so the two
sides can be compared "before anything secret is sent". The probe was built; the
comparison was not — `version` was parsed into `SessionInfo` and used nowhere, so a PC
running an older nestwatch than this app expects surfaced as a parse failure on some
screen with no sentence anywhere saying the two had disagreed.

`ContractCheck` compares it against `testedAgainst`, which is the nestwatch release
`test/golden/` was captured from — a narrow claim, and a true one: *these* shapes were
checked against *that* nestwatch. Major and minor only; nestwatch is pre-1.0, where minor
carries the breaking changes, and warning on a patch bump would put a notice in front of a
parent for a release that cannot have moved anything this app reads.

Three outcomes again, and again the third is the point:

| | shown as |
|---|---|
| same major.minor | nothing, except a line in the identity dialog |
| that PC is **older** | a warning strip on every screen — a screen is going to break, and the parent holds the fix |
| that PC is **newer** | said once, without alarm: this app is the one that is behind |
| no version to read | *"could not check whether the two agree"* — never rendered as silence |

The warning appears **above the password field**, not after it, which is the whole of what
§5 meant by "before anything secret is sent".

`check_golden.sh` keeps `testedAgainst` honest by comparing it to the sibling checkout's
`Cargo.toml`. That is a second reader of nestwatch's source and the first one had to be
deleted, so the difference matters: `version` under `[package]` is not a name anyone chose
— cargo requires that exact key, and renaming it breaks the build over there long before
it can mislead over here. It still shouts `UNREADABLE` if either side goes quiet, and both
halves of that were watched to fire.

## Mutation audit

```bash
./tool/mutate.sh    # breaks one behaviour at a time, checks the suite notices
```

A green suite says nothing about whether it *would* go red. Each mutation is a real defect
this codebase argues against somewhere in its comments; a `SURVIVED` line means the
argument is not defended by a test.

The run ends with `killed=N survived=N anchors-missing=N` and exits non-zero unless the
last two are zero. That count is not repeated here on purpose. This file used to say
"65 tests" and "22 killed" while the suite reported 123 and 28 — a number copied into
prose with nothing checking the copy, which is the exact failure the rest of this
document is about, one layer up. The commands print the current figures; nothing here
can drift from them if nothing here restates them.

It has found six genuine gaps so far, each now closed:

| mutation that survived | why it mattered |
|---|---|
| `?tier=preview` deleted | trap 4 — a valid 200 JPEG at the expensive tier, shredding the audit log |
| unknown stored provenance read as **verified** | a storage-format change silently promoting trust-on-first-use |
| a `401` from `/api` read as an unexpected answer | sends a parent back through pairing when only the session lapsed |
| any `Set-Cookie` taken as the session | an unrelated cookie standing in, the real one never missed |
| a cleared session kept and retried | the app believes it is signed in while every request is anonymous |
| notify before persisting the seen-set | a crash between the two re-announces, teaching the parent to swipe it away |

Five of those were reachable only through `prove_*` harnesses, which need live servers and
so never run in CI.

One test also turned out to assert a property its own fixture could not exercise: the
"does not follow the redirect" check passed because the stub answered `200`, so there was
never a redirect to follow. The stub now really returns `302`.

Two lessons are baked into the script itself, both from false gaps it reported:

- **A mutation that lands in a comment always survives**, and looks exactly like missing
  coverage. This codebase is comment-dense, so a prose-like anchor hits the prose first.
  The script now diffs comment-stripped source and reports `NO-OP (hit a comment)`.
- **`//` inside a URL is not a comment.** The first version of that guard used
  `re.sub(r'//.*', '')`, which gutted every line containing `https://` and so declared a
  real mutation a no-op. It strips only whole-line comments now.

Mutation-checked: making `badCertificateCallback` always accept fails 5 of its 7 tests.
Flipping `withTrustedRoots` to `true` fails **none** of them — the fixtures are
self-signed, so they fail under either setting and the callback fires regardless.
Reaching that trap needs a certificate the platform genuinely trusts, which no test can
obtain for `127.0.0.1`. That limit is recorded in the test file and beside the code.

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

## When the PC cannot do the thing

`AppError::Control` (nestwatch `src/error.rs`) covers every OS operation that can fail —
capture, process list, kill, shutdown — and answers **500** with the OS detail logged
rather than leaked, so the body says only `"operation failed"`. The status names the layer
that gave up and never the reason.

`screenshotPreview()` is the one call site that knows what it asked for, so it is the only
place the message can be specific: a failed capture is almost always Windows older than
1903, where the capture API is simply absent and every screenshot fails while the rest of
the app works normally. "HTTP 500" on that screen is close to useless; the real cause is
common and fixable. Live view also stops itself on that failure — retrying every five
seconds against a PC that structurally cannot capture is a loop, not a recovery.

## Connection reuse

`NestwatchClient` holds one `HttpClient` and reuses it. Measured against a live server by
counting rustls' per-handshake log line: **10 sequential requests cost 1 TLS handshake,
where a client-per-request cost 10.** At the live-view screen's 5-second cadence that was
a full handshake every five seconds.

Reuse is safe because the pin is enforced during the handshake — a pooled connection is
one whose certificate already satisfied `badCertificateCallback`, so a second request over
it inherits that check rather than skipping one.

What reuse must not survive is a **change of pin**: a pooled socket was established under
whatever was trusted at the time, and re-pairing does not reach into a live pool.
`PairingController._clientFor` therefore closes the previous client before building a new
one, as do `signOut`, `unpair` and `dispose`.

## Android notes

- `compileSdk = 37`, above Flutter's default of 36, because `flutter_secure_storage` 11
  requires it. `minSdk` stays at Flutter's 24, which clears every plugin floor.
- Core library desugaring is enabled — `flutter_local_notifications` 10+ declares the
  requirement in its AAR metadata, so without it the build fails at
  `:app:checkDebugAarMetadata` rather than crashing on an old phone at runtime.
- `INTERNET` is declared in the **main** manifest. Flutter's template puts it only in
  `debug`/`profile`, so a release build would ship with no network access.
- The MLKit barcode model is **bundled**, not downloaded — see `android/gradle.properties`
  for why the usual size-saving advice is wrong here.
- `mobile_scanner` still applies the Kotlin Gradle Plugin directly, which Flutter warns
  will stop working in a future release. Not breaking today; worth watching on upgrade.

## Layout

Directories, not files. This used to be a list of six filenames, one of which described
`main.dart` as the "step-2 probe screen" it had long since stopped being — a hand-written
map goes stale faster than the thing it maps, and directories are what this repo adds
files to rather than what it adds.

```
lib/src/pinning/     the pin itself: fingerprints, the HttpOverrides, and the
                     sentence a parent reads when a certificate is refused
lib/src/pairing/     what to trust and how sign-in is reached — deliberately free
                     of Flutter imports, so it runs under plain `dart run`
lib/src/api/         the wire: request building, failure mapping, the parsed
                     shapes, and the version comparison against that PC
lib/src/ui/          four screens and the pieces they share (polling, notices)
lib/src/background/  both notification tiers, and the isolate that must re-pin
tool/prove_*.dart    harnesses that run against a live server, never a mock
tool/*.sh            the audits: mutations, the cross-repo contract, dependencies
test/golden/         nestwatch's own serde output, vendored
```
