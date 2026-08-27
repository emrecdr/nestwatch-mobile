# Golden files, copied from nestwatch

Nine files produced by nestwatch's own serde types (`tests/golden.rs`) — eight covering
every JSON shape this app parses, plus `limits.json`. They are the contract between the two repos, and until now
that contract had only ever been read as prose — twice, by two different sessions, which
is also how two people misread it the same way.

**Source:** `nestwatch` `tests/golden/`, at `18e3b49` (0.4.0).

## Why copied rather than read in place

They are tracked in nestwatch now, so nothing here depends on anyone not tidying up. What
a copy buys is different: `test/models_golden_test.dart` runs on a machine that has this
repo and nothing else. Reading the sibling path would mean skipping when it is absent, and
a test that quietly stops running is worse than one that was never written — it reports
success either way. That failure happened in this repo the same afternoon these files
landed: a mutation anchor stopped matching, the count went 24 to 23, and the audit still
printed `survived=0`.

## limits.json is not a response shape

The other eight files are JSON this app receives. `limits.json` is five numbers it
*renders before it can ask* — "1 to 240 minutes" on the time-codes screen, "5 tries, then
a minute" on a lockout — compiled into the client from its own constants. A client whose
copy has drifted misinforms a parent without ever making a call that could correct it,
which is why a runtime `/api/limits` would not have helped: the screen is drawn before a
request could return.

It replaced a worse channel. This app used to read those constants by grepping nestwatch's
source, and the failure mode there is that the check *stops running* rather than that a
number is wrong. That is not hypothetical: the constants were given names on the nestwatch
side hours after the reader was written — an improvement there — and it disarmed the
reader here. It said so loudly, which is the only reason either session noticed.

## Keeping the copy honest

`tool/check_golden.sh` diffs these against nestwatch's when that repo is present, and says
so plainly when it is not. Run it after any change to either side's wire format. To
refresh: re-run it, and it will tell you exactly which files drifted.
