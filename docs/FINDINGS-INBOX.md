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

*(Empty. IN1, IN2 and IN3 were validated against this tree on 2026-08-31, found real,
and fixed in the same pass — so there was nothing to promote into the register. `git log`
holds what they were; the commit names each one.)*

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
