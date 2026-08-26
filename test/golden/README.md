# Golden files, copied from nestwatch

Eight files produced by nestwatch's own serde types (`tests/golden.rs`), covering every
JSON shape this app parses. They are the contract between the two repos, and until now
that contract had only ever been read as prose — twice, by two different sessions, which
is also how two people misread it the same way.

**Source:** `nestwatch` `tests/golden/`, at `fe1cd34`.

## Why copied rather than read in place

They are tracked in nestwatch now, so nothing here depends on anyone not tidying up. What
a copy buys is different: `test/models_golden_test.dart` runs on a machine that has this
repo and nothing else. Reading the sibling path would mean skipping when it is absent, and
a test that quietly stops running is worse than one that was never written — it reports
success either way. That failure happened in this repo the same afternoon these files
landed: a mutation anchor stopped matching, the count went 24 to 23, and the audit still
printed `survived=0`.

## Keeping the copy honest

`tool/check_golden.sh` diffs these against nestwatch's when that repo is present, and says
so plainly when it is not. Run it after any change to either side's wire format. To
refresh: re-run it, and it will tell you exactly which files drifted.
