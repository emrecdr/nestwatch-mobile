# Hardening and improvements, after nestwatch 0.4.0

Written 2026-08-27, against nestwatch `18e3b49` (0.4.0) and this repo at `ac2c7c3`.

## How this list was made

Every item was checked against the code rather than recalled, and each says plainly
whether it is **verified** (something was read or run) or **reasoned** (a documented
platform behaviour applied to this app). Standards consulted: OWASP MASVS, Android's own
foreground-service and backup documentation, and Play Console policy for monitoring tools.

Items are ordered by what they protect, not by effort.

---

## 1. `/api/events` — the thing 0.4.0 unlocked

**Verified.** nestwatch now serves Server-Sent Events at `GET /api/events`
(`src/api.rs`), emitting bare tags — `requests`, `usage`, and `all` when a subscriber has
fallen behind — with `data: "1"`. No payload; it is a nudge to refetch. Authenticated and
LAN-gated like the rest of `/api`, with an explicit `no-store` so the "nothing under
`/api` is ever stored" rule keeps its no-exception form.

PLAN §7 deferred long-polling with a precise reason: *"it changes server behaviour for a
client that does not exist yet. Revisit once the app is real."* The app is real and the
server behaviour changed anyway — for its own dashboard, which now sees a new request in
a second or two instead of up to a minute.

**What it buys here.** The watch-now tier polls every 60 s for a queue that changes a few
times a day. An event stream replaces roughly 60 requests an hour with one held
connection, and cuts worst-case latency from 60 s to about one.

**What it does not buy.** The 15-minute WorkManager tier gains nothing — that isolate is
not alive to hold a stream. And the `dataSync` budget is measured in *service runtime*,
not requests, so watch-now still gets six hours per 24.

**Shape.** Follow the dashboard: keep the 60 s poll as a backstop and let events only
trigger an early refetch. A stream that dies must degrade to plain polling rather than
leave a screen frozen — and, per this repo's habit, must say which mode it is in rather
than let "connected but silent" look like "nothing has happened".

## 2. The child's desktop is in the app switcher

**Reasoned, from documented Android behaviour.** Nothing in this app sets `FLAG_SECURE`
(verified: no match in `android/` or `lib/`). Without it, Android captures a thumbnail of
the current screen for the recents list, and any screen-recording app can read the
window. The Screen tab renders a live picture of a child's desktop.

So the most private thing this app displays is also the thing that lands in a thumbnail
anyone can see by pressing Recents on an unlocked phone, and survives in memory after the
app is backgrounded. OWASP MASVS files exactly this under MASVS-STORAGE — screenshot
caches are named as a top source of unintentional leaks.

**Recommendation: set it for the whole activity, always**, via a ~15-line `MethodChannel`
in `MainActivity` rather than a package — nothing here needs a dependency. Applying it
only while the Screen tab is visible leaves a real gap (the toggle races the thumbnail
capture on the way out) and costs a parent the ability to screenshot the fingerprint for
their own records, which the identity dialog already shows as selectable text.

## 3. The child's own words, on a lock screen

**Verified.** `notifications.dart` sets no `visibility`, and the notification body is the
child's free-text reason:

```dart
body: request.reason.isEmpty
    ? 'Your child asked for more screen time.'
    : request.reason,
```

Whether that text appears on a locked screen depends on a per-user Android setting, so
this is not "always leaking" — it is "leaking or not, depending on a setting this app
never consults and the parent probably never changed."

**Recommendation.** Set the visibility explicitly and supply a public version that carries
the count and not the words: *"1 request waiting"*. The reason is exactly the sentence a
child would least like read aloud from a phone on a kitchen table, and it adds nothing at
lock-screen glance — the parent has to open the app to act either way.

## 4. The certificate expiry only the PC can see

**Verified on both sides, and it is an asymmetry rather than a bug.**

nestwatch issues certificates for `VALIDITY_DAYS = 825` and starts warning at
`RENEW_WARN_DAYS = 30` — but into the service log and `doctor`, which live on the child's
PC. The parent reads neither.

The phone has the answer in its hand: `badCertificateCallback` receives an
`X509Certificate` with `endValidity` on it, and this app reads `startValidity` only
(`pinned_http_overrides.dart:177`, for the mismatch screen).

It gets worse in an interesting way. Because the pin is the sole authority — the callback
returns `true` on a fingerprint match and Dart asks nothing further — **an expired
certificate keeps working on the phone**. The browser hard-fails on the same certificate.
So the failure a parent actually meets is: the dashboard breaks, the phone is fine, and
every instinct says the PC is broken rather than that a certificate lapsed.

**Recommendation.** Read `endValidity` in the callback, store it beside the pin, and warn
at nestwatch's own 30-day threshold rather than a number invented here — with the sentence
naming what will happen (re-running `install --new-cert` re-pairs every device) so the
parent picks the moment instead of discovering it.

## 5. Backup rules

**Verified: no `android:allowBackup` and no `dataExtractionRules` in the manifest**, and
no `res/xml/`. The platform default is backup-enabled.

**Be honest about the size of this.** The stored pin and session cookie are encrypted
under a non-exportable Keystore key, so a backup carries ciphertext nobody can decrypt off
the device, and `resetOnError: true` means a restored, undecryptable blob is cleared
rather than enforced — which fails in the safe direction, since a lost pin forces
re-pairing. This is defence in depth, not a hole.

It is still worth doing: Google's own guidance is to exclude Keystore-encrypted
preferences from Auto Backup, precisely because restoring them produces data whose key is
gone. Declaring the exclusion also makes the intent legible to the next reader.

## 6. The release build is signed with debug keys

**Verified.** `android/app/build.gradle.kts:46` still carries the scaffold's
`signingConfig = signingConfigs.getByName("debug")` under `release`, with the generated
TODO above it.

Needed before any upload, and worth doing together: a real keystore (with Play App
Signing), R8 enabled, and `--obfuscate --split-debug-info` so stack traces stay readable
without shipping symbol names. None of this is security theatre for a LAN app, but the
debug key is a genuine "anyone can sign an update that looks like yours" problem the day
this leaves the machine.

## 7. The privacy policy has to be *in the app*

**Verified against current policy.** Play requires the policy at a publicly reachable URL
in the Console field **and** linked from within the app itself. This repo has neither, and
the second half is the one people forget.

The content is unusually easy to write honestly here — nothing leaves the house, there is
no analytics SDK, no ad ID, no account — but it must name screenshots of the child's
desktop as that child's personal data, which is the sentence the whole design exists to
justify. The Data safety form has to agree with it.

---

## Considered, and not recommended

- **Root or tamper detection.** Defeats nothing an attacker with root cannot undo, and the
  integrity property that matters — a rewritten pin — is already covered by AES-GCM under a
  Keystore key.
- **Play Integrity API.** Requires a server to verify the token. This design forbids the
  monitored PC from making outbound connections, so there is nowhere to verify it.
- **A backup SPKI pin.** PLAN §2 settled this: `cert::generate()` makes a new key *and*
  certificate, so SPKI pinning gains nothing over leaf DER here. Nothing has changed.
- **Certificate Transparency checks.** CT is about publicly-trusted issuance. This
  certificate is self-signed by design and will never appear in a log.
- **Long-polling `?wait=25`.** Superseded — item 1 does the same job with a mechanism that
  already exists and that nestwatch's own dashboard depends on.
