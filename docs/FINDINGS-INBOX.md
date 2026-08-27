# Findings inbox

**Proposals from outside this repo.** Everything here was written by a session whose own
codebase is somewhere else. Nothing here has been validated against this tree by anyone who
can run its tests.

This file is a **queue**: entries arrive, get judged, and leave. `docs/OPEN-FINDINGS.md` is a
**register**: entries stand until the work is done. They were fighting inside one file because
those are different lifecycles, and this split is the fix.

## The rule

- **A session working out of another repo writes here, and only here.** Never directly into
  `docs/OPEN-FINDINGS.md`.
- **Only a session working in *this* repo promotes an entry into `docs/OPEN-FINDINGS.md`,
  and only after validating it here** — running the claim against this tree, not re-reading
  the argument and finding it persuasive.
- **Promotion deletes the inbox entry** and re-files it under a local `M##`. `git log` holds
  what was proposed and by whom.
- **Rejection also deletes the entry**, with the reason recorded wherever the claim was
  argued — same convention as `OPEN-FINDINGS.md` uses for a withdrawn finding.

Entries are numbered `IN##` so a proposal can be cited before it has a local ID, and so the
two namespaces cannot be confused in a commit message.

## Why the rule exists

It was derived from a deadlock, not invented. On 2026-08-27 a session working in
`../nestwatch-mobile` wrote a finding into `../nestwatch/docs/OPEN-FINDINGS.md` as `O72`.
Two sessions working in nestwatch each found the file dirty and each declined to commit it,
for the same reason and independently: **you cannot vouch for prose you did not write, and
committing it puts another session's reasoning under your name in `git blame`.** The entry
was correct and useful, and it sat uncommitted anyway, because the file it landed in had no
way to hold a proposal as distinct from a decision.

Three things this buys:

- **Provenance stays truthful.** Each repo's own session commits its own register.
- **Nothing unvalidated becomes canonical.** An `M##` means somebody ran it here.
- **A cross-repo claim carries its own uncertainty.** The proposer states what they could
  verify from over there and what they could not, instead of having to write with a
  confidence they do not have.

## What an entry owes the reader

State what you actually ran, and where you ran it. A finding proposed from another repo is
worth what its evidence is worth: *"measured on 2026-08-27 by running X, output Y"* is
usable, and *"reading the code suggests"* is a request for someone else to do the work — say
so plainly when that is what it is, rather than dressing it up.

---

## Awaiting validation

### IN1 · For the first 24 hours after a certificate expires, the app says it has not

**From** the nestwatch session (`../nestwatch`), 2026-08-27. **Measured, not read.**

`CertificateExpiry.of` computes `notAfter.difference(at).inDays`. Dart's `Duration.inDays`
truncates toward zero, so every offset strictly between −24 h and 0 yields `0`, and `0` does
not satisfy the `< 0` guard that selects `CertificateLife.expired`. It falls through to
`<= renewWarnDays` and is classified `expiringSoon`.

**How this was measured.** Against the real class, not a copy — `certificate_expiry.dart`
has no imports, so it runs standalone under `dart run` with a file import. Output on
2026-08-27:

```
expired  1 minute ago  -> life=expiringSoon daysLeft=0 isWarning=false
expired  6 hours ago   -> life=expiringSoon daysLeft=0 isWarning=false
expired 23h59m ago     -> life=expiringSoon daysLeft=0 isWarning=false
expired 24h01m ago     -> life=expired      daysLeft=-1 isWarning=true
```

**Why it is worse than an off-by-one.** The two sentences are not near-neighbours; they tell
opposite stories, and the wrong one is told during the window when a parent is most likely to
be reading it. Inside that 24 hours the app says:

> That PC's certificate **expires in 0 days**. This app will keep working, but the dashboard
> in a browser **will stop**.

The browser has already stopped. That is the moment the parent goes looking, and
`CertificateExpiry`'s own library doc states this is the exact confusion the class exists to
prevent — *"the dashboard breaks, the phone is fine, and every instinct points at the PC being
broken rather than at a certificate having lapsed."* For 24 hours the class actively
reinforces the misdiagnosis it was written to prevent. `isWarning` is also `false` throughout,
so the permanent caveat strip in `HomeScreen` stays silent for that whole day.

**Why the suite does not catch it.** `certificate_expiry_test.dart` is thorough about the
boundary it tests and every case is a whole number of days — `at(int daysFromNow)` cannot
express a fractional offset, so the defect is not merely untested, it is *unreachable* by the
test's helper. Real certificates expire at a time of day, so production hits the untestable
region every time.

**Proposed fix, for a local session to weigh.** Compare against the instant rather than the
truncated count — decide `expired` on `!notAfter.isAfter(at)`, and keep `inDays` only for the
number rendered in the sentence. Worth checking the other end of the same truncation while
there: a certificate 30 days and 12 hours out also reports `30` and lands in `expiringSoon`,
which is harmless but is the same arithmetic.

**Not verifiable from outside this repo:** whether the day-0 phrasing (*"expires in 0 days"*)
is wanted at all once the classification is fixed, or whether that day should read *"expires
today"*. That is a copy decision for whoever owns the parent-facing voice.

---

### IN2 · The privacy screen promises "Forget this PC" deletes three things; it deletes two

**From** the nestwatch session (`../nestwatch`), 2026-08-27. **Read, and traced to the call
site — no device needed to confirm it.**

`PrivacyScreen` enumerates exactly three stored items — the certificate fingerprint, the
sign-in cookie, and *"the identifiers of requests you have already been told about"* — and
then states:

> All three are held in Android's encrypted store … **"Forget this PC" deletes all of them.**

`PairingController.unpair` clears two of them: `_sessions.clear()` and `_identities.clear()`.
The third is never cleared, and **cannot be** at the call site as things stand: the
`SeenRequestStore` interface declares only `load` and `save`. There is no `clear` to call.
`SecureServerIdentityStore` and `SecureSessionStore` both have one; `SecureSeenRequestStore`
does not.

**Why this is filed as a defect rather than a tidy-up.** It is not that some state outlives
an unpair — it is that a sentence written to a parent, on the screen whose entire job is to
be accurate about what the app retains, is false. This repo's own `M7` records that the
published privacy policy has to match this in-app text and that a Play Data safety form has to
agree with both, so the error does not stay in one file; it propagates into store paperwork
and into a public URL.

The residual behaviour is worth stating too, because it is what a reader will ask: request
identifiers look like `1993f2c8a10-3` (a millisecond timestamp plus a counter, per nestwatch's
`time_requests` golden), so a surviving set can suppress a genuine notification on a
newly-paired PC only on an exact ID collision — unlikely, not impossible, and silent when it
happens. The promise being false is the finding; the collision is a footnote.

**Proposed fix, for a local session to weigh.** Add `clear()` to `SeenRequestStore`, implement
it on both the secure and in-memory stores, and call it from `unpair` beside the other two. A
test that unpairs and then asserts all three stores are empty would pin the privacy screen's
sentence to the code — which is the property that was missing, since nothing currently
connects that copy to any behaviour.

**Not verifiable from outside this repo:** whether `unpair` is the only path that should clear
it, or whether signing out should too. Signing out is explicitly *not* an unpair here
(`_onFailure` handles a lapsed session without disturbing the pin), so this is a judgement
about what "already been told about" should survive, and it belongs to whoever owns that
distinction.

---

### IN3 · The 30-day warning only reaches a parent who goes looking, which is the premise the class rejects

**From** the nestwatch session (`../nestwatch`), 2026-08-27. **This one is an argument, not a
measurement — weigh it as such.**

Filed with a caveat: `HomeScreen`'s caveat-strip comment shows this was considered, and the
decision recorded there is sound as far as it goes. I am not asking for it to be reversed. I
think the choice was made between two options when there is a third.

What is there now: `_caveats` admits an expiry message only when `expiry.isWarning`, and
`isWarning` is true only for `CertificateLife.expired`. So the `expiringSoon` sentence — the
whole 30-day window — renders in exactly one place, the identity dialog behind the app-bar
icon. The comment gives the reason: *"being a month from expiry [still works] everywhere, and
belong[s] in the identity dialog rather than banded across every screen."* As a judgement
about a **permanent strip**, that is right. A strip that stands for thirty days is furniture
by day three.

The gap is that the alternative to a permanent strip was taken to be *no proactive surface at
all*. `CertificateExpiry`'s library doc argues the class exists because nestwatch's own warning
goes *"into the service log and `doctor`, both of which live on the child's PC. The parent
reads neither."* A dialog behind an icon a parent taps when they are already wondering about
identity is the same shape of surface: correct, present, and visited only by someone who
already suspects. The sentence itself is written for a parent who has *not* thought about it
— *"it is worth picking the moment rather than being caught by it"* — and by the time that
sentence is reachable in practice, they have been caught by it.

**Options a local session might weigh**, none of them a permanent strip: show it once per
entry into the window and not again; show it only inside the last few days; or leave it
exactly as-is on the grounds that 825-day certificates make this rare enough that the identity
dialog is proportionate. That last one is a perfectly good answer — but it should be the
answer to *this* question, rather than a side-effect of answering the strip question.

**Related to IN1.** If IN1 is fixed, the first honest `expired` day arrives 24 hours earlier,
which slightly reduces what this costs. It does not remove it.

---

## Scope of this pass, stated honestly

Reviewed on 2026-08-27 from `../nestwatch`: the pinning layer
(`PinnedHttpOverrides`, `Fingerprint`, `CertificateExpiry`), the secure stores, the unpair
path, and the `HomeScreen` caveat wiring. **Not reviewed:** `ServerEvents` reconnect
behaviour, the `ValueNotifier` wiring in `HomeScreen`, `poll_logic.dart`, the background
session, and every UI screen other than `HomeScreen` and `PrivacyScreen`. The local session
named the first two as the least-reviewed code in the repo; they remain so after this pass.

**One thing deliberately not filed.** `Fingerprint.parse` accepts a sign character inside a
byte pair, because `int.tryParse(radix: 16)` does — so a mistyped pin containing `-` or `+`
can parse to a value other than the one on screen instead of throwing, despite the doc's claim
to be *"strict about length"*. It fails closed (a wrong pin refuses the handshake), so it is a
diagnostics wart rather than a hole, and I could not judge from outside whether the leniency
is load-bearing for the three input routes the doc names. Recorded here rather than as an
entry so it is not lost, and so it does not spend a slot in the register.
