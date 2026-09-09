/// The "Refused today" sentences, and the constraint that makes them safe to show.
///
/// nestwatch sends counts and no prose, so this side composes it — which means this side
/// also owns the risk. The counts describe three things a child can do deliberately, and
/// the difference between a card that survives contact with a teenager and one that starts
/// an argument is entirely in the wording.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/api/models.dart';
import 'package:nestwatch_mobile/src/ui/refusal_lines.dart';

import 'support/source.dart';

Refusals _of({
  int clock = 0,
  int resets = 0,
  int shutdowns = 0,
  int codes = 0,
}) => Refusals(
  clockChanges: clock,
  dayResets: resets,
  shutdownCancels: shutdowns,
  timeCodesRefused: codes,
  total: clock + resets + shutdowns + codes,
);

void main() {
  group('nothing here accuses anybody', () {
    // nestwatch asserts its own copy never uses these, and the reason transfers whole: a
    // family that genuinely crossed a time zone produces exactly the same counts as a
    // clock moved on purpose. The card cannot tell them apart and must not imply it can.
    //
    // Held as a test rather than as a comment in `refusal_lines.dart`, because a comment
    // cannot fail. The words are checked against every string this file can produce,
    // including the heading and the intro, not only the numbered lines.
    const forbidden = [
      'tamper',
      'caught',
      'cheat',
      'suspicious',
      'attack',
      'violation',
      'blame',
    ];

    test('not in any line, at any count', () {
      final everything = <String>[
        refusalsTitle,
        refusalsIntro,
        // 1 and 2 because the singular and plural are different strings, and a word could
        // hide in either. 0 produces no line, which the next group covers.
        for (final n in [1, 2])
          ...refusalLines(_of(clock: n, resets: n, shutdowns: n, codes: n)),
      ];

      expect(
        everything,
        hasLength(10),
        reason: 'title, intro, and four lines twice',
      );

      for (final text in everything) {
        for (final word in forbidden) {
          expect(
            text.toLowerCase(),
            isNot(contains(word)),
            reason:
                '"$word" turns a fact about what this tool did into a claim '
                'about what somebody meant by it',
          );
        }
      }
    });

    test('and the intro says the limits held, which is the point', () {
      // Without this the card is three counts and no verdict, and a parent reading it at
      // 22:00 has no way to know whether anything needs doing tonight.
      expect(refusalsIntro, contains('limits held'));
      expect(refusalsIntro, contains('nothing here needs fixing'));
    });
  });

  group('a zero is not a line', () {
    test('nothing at all when nothing was refused', () {
      expect(refusalLines(Refusals.none), isEmpty);
    });

    test('only the non-zero ones appear', () {
      final lines = refusalLines(_of(resets: 3));
      expect(lines, hasLength(1));
      expect(lines.single, contains('start the day over'));
      expect(
        lines.single,
        isNot(contains('clock')),
        reason: 'a zero count must produce no line, not a line saying zero',
      );
    });
  });

  group('the count leads the line, and agrees with itself', () {
    test('singular at one', () {
      expect(
        refusalLines(_of(clock: 1)).single,
        startsWith('1 clock change ignored'),
      );
      expect(
        refusalLines(_of(shutdowns: 1)).single,
        startsWith('1 shutdown cancelled on the PC'),
      );
    });

    // No separate "plural above one" case. It asserted `_of(clock: 2)` starts with
    // "2 clock changes ignored" -- the same input the test below pins in full, and
    // `_plural` branches only on `n == 1`, so 9 exercises nothing 2 does not. It made a
    // wording change three edits instead of two and produced a second failure carrying no
    // information the first did not. The `_plural => many` mutation is still killed by
    // `singular at one`.
    test('the wording matches the dashboard, so one event has one name', () {
      // Copied from `refusedRows()` in nestwatch `assets/app.js`. Two surfaces inventing
      // separate vocabularies for the same four facts is how a parent ends up wondering
      // whether they are reading about the same event.
      //
      // Re-read against their table on 2026-09-09 when 0.8.0 added the fourth: these three
      // are unchanged there. Worth doing rather than assuming, because a copy stops being
      // a copy without anything failing.
      expect(
        refusalLines(_of(clock: 2)).single,
        '2 clock changes ignored — screen time and bedtime kept using the trusted time',
      );
      expect(
        refusalLines(_of(resets: 1)).single,
        "1 attempt to start the day over refused — today's total stood",
      );
      expect(
        refusalLines(_of(shutdowns: 3)).single,
        '3 shutdowns cancelled on the PC — re-issued straight away, without a fresh '
        'countdown',
      );
      // The fourth, from nestwatch 0.8.0. Both counts are pinned in full rather than one,
      // because unlike the three above this pair differs *after* the dash as well as
      // before it, so a plural bug here can hide in the half the others do not have.
      expect(
        refusalLines(_of(codes: 1)).single,
        '1 time code refused — it was not an active code, so no time was added',
      );
      expect(
        refusalLines(_of(codes: 2)).single,
        '2 time codes refused — they were not active codes, so no time was added',
      );
    });

    test('all four, in the dashboard order', () {
      final lines = refusalLines(
        _of(clock: 1, resets: 1, shutdowns: 1, codes: 1),
      );
      expect(lines, hasLength(4));
      expect(lines[0], contains('clock'));
      expect(lines[1], contains('day over'));
      expect(lines[2], contains('shutdown'));
      expect(lines[3], contains('time code'));
    });
  });

  group('the total is the server, not this app', () {
    // **This group used to pass while the parsing was undefended**, and the mutation audit
    // is what said so: replacing `total:` with a local sum of the three parts survived.
    // The test below it constructed a `Refusals` by hand, so it exercised `any` and
    // `refusalLines` and never once went through `fromJson` — which is where the decision
    // it argues for actually lives. A comment claiming a rule, and a test one layer away
    // from it.
    test('a total larger than the parts is taken as sent, through fromJson', () {
      // Not a hypothetical server. This is the *next* one: `refused_total` is sent beside
      // the counts precisely so that the day nestwatch declines a fourth kind of thing,
      // the sum moves and the three named parts do not. A client that re-added them would
      // report that day as quiet. nestwatch's own note is that the total rides along "so
      // the client does not add a fourth place that knows how to sum these".
      final refused = Refusals.fromUsage(const {
        'refused': {'clock_changes': 1, 'day_resets': 0, 'shutdown_cancels': 0},
        'refused_total': 5,
      });

      expect(refused.total, 5, reason: 'as sent, not 1');
      expect(refused.any, isTrue);

      // And the rendering stays honest about it: one sentence for the kind this version
      // can name, and no invented line for the four it cannot.
      //
      // **It does not say "and 4 others", and that was decided rather than overlooked.**
      // The dashboard behaves identically -- `refusedRows()` itemises the three it knows
      // and never mentions a remainder -- but it ships *with* the server, so it can never
      // be behind one. This app can, which is the whole reason `ContractCheck` exists. A
      // per-field "I did not recognise this" line would be a special case layered on a
      // mechanism that already covers it, which is the shape this repo treats as a sign
      // the fix is at the wrong depth.
      //
      // **One clause of that argument was wrong, and is corrected here rather than
      // quietly dropped.** It used to say `ContractCheck` "already puts *that PC is
      // running a newer nestwatch* in front of the parent". It does not. `isWarning` is
      // `serverOlder` alone, so `serverNewer` never reaches `_caveats` and never bands a
      // screen -- `home_screen.dart` says why in as many words, that being newer "still
      // works everywhere". The message exists; it is in the identity dialog, behind a tap.
      //
      // Which leaves the refusals card as a counterexample to *that* claim: newer is
      // exactly when this count is short, and it is the one agreement with no banner. The
      // conclusion may still be right -- the depth argument above does not depend on the
      // clause that was wrong -- but M33 records it so the trade is made knowing which
      // half of it is true. Checked 2026-09-08 against `server_contract.dart` and
      // `home_screen.dart`, not from memory.
      expect(refusalLines(refused), hasLength(1));
      expect(
        refusalLines(refused).single,
        startsWith('1 clock change ignored'),
      );
    });

    test('a missing total reads as nothing to show, not as the sum', () {
      // Reading the parts instead would put a section in front of a parent that the
      // server never said anything about.
      final refused = Refusals.fromUsage(const {
        'refused': {'clock_changes': 3, 'day_resets': 2, 'shutdown_cancels': 1},
      });
      expect(refused.total, 0);
      expect(refused.any, isFalse);
    });

    // The moment the decision above has to be made again, held so it cannot be missed.
    //
    // Naming a fourth kind of refusal takes two edits: a field on `Refusals`, and a
    // sentence in `refusalLines`. Doing the first without the second is silent — the
    // count parses, `total` already covered it, and the card renders exactly as before
    // while one category goes unmentioned. Nothing would fail.
    //
    // Deliberately says nothing about a category this app does *not* parse, which is the
    // question the test above weighs and settles the other way. This only asks that the
    // model and the prose stay in step with each other.
    //
    // Read out of the source because Dart has no reflection here, which is the same
    // reason `flag_secure_test` and `ios_config_test` read files: the check has to live
    // somewhere and the only somewhere is the text.
    test('every count on Refusals has a sentence to go with it', () {
      final model = readSourceOrFail(
        'lib/src/api/models.dart',
        why: 'Refusals is the list of refusal kinds this app can name',
      );
      final start = model.indexOf('class Refusals {');
      expect(
        start,
        isNot(-1),
        reason: 'class Refusals is not where this expects it',
      );
      final body = model.substring(start, model.indexOf('\n}', start));

      // `total` is the server's sum, not a kind, and has no sentence by design.
      final counts = RegExp(r'^  final int (\w+);', multiLine: true)
          .allMatches(body)
          .map((m) => m.group(1)!)
          .where((name) => name != 'total')
          .toList();

      // Without this the scan passes by reading nothing, which is the failure mode of
      // every source-reading check in this repository.
      expect(
        counts,
        contains('clockChanges'),
        reason:
            'the field scan has stopped matching, so it can no longer object',
      );
      expect(counts, hasLength(greaterThanOrEqualTo(3)));

      final prose = readSourceOrFail(
        'lib/src/ui/refusal_lines.dart',
        why: 'the sentences composed for those counts',
      );
      for (final name in counts) {
        expect(
          prose,
          contains('refused.$name'),
          reason:
              '`Refusals.$name` is parsed and never mentioned. The card would render '
              'as though that kind of refusal did not happen.',
        );
      }
    });

    test('a payload with no `refused` at all is `none`, not zeros it invented', () {
      // A server predating the field sends neither key. Now that the reader takes the
      // whole payload, that case is its own branch rather than a `switch` at the call
      // site -- so this is where it is pinned.
      expect(Refusals.fromUsage(const {'used_mins': 10}).any, isFalse);
      expect(Refusals.fromUsage(const {'used_mins': 10}).total, 0);
    });
  });
}
