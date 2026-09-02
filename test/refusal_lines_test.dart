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

Refusals _of({int clock = 0, int resets = 0, int shutdowns = 0}) => Refusals(
  clockChanges: clock,
  dayResets: resets,
  shutdownCancels: shutdowns,
  total: clock + resets + shutdowns,
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
          ...refusalLines(_of(clock: n, resets: n, shutdowns: n)),
      ];

      expect(
        everything,
        hasLength(8),
        reason: 'title, intro, and three lines twice',
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
      // separate vocabularies for the same three facts is how a parent ends up wondering
      // whether they are reading about the same event.
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
    });

    test('all three, in the dashboard order', () {
      final lines = refusalLines(_of(clock: 1, resets: 1, shutdowns: 1));
      expect(lines, hasLength(3));
      expect(lines[0], contains('clock'));
      expect(lines[1], contains('day over'));
      expect(lines[2], contains('shutdown'));
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
      // be behind one. This app can, which is the whole reason `ContractCheck` exists and
      // already puts "that PC is running a newer nestwatch" in front of the parent. A
      // per-field "I did not recognise this" line would be a special case layered on a
      // mechanism that already covers it, which is the shape this repo treats as a sign
      // the fix is at the wrong depth.
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

    test('a payload with no `refused` at all is `none`, not zeros it invented', () {
      // A server predating the field sends neither key. Now that the reader takes the
      // whole payload, that case is its own branch rather than a `switch` at the call
      // site -- so this is where it is pinned.
      expect(Refusals.fromUsage(const {'used_mins': 10}).any, isFalse);
      expect(Refusals.fromUsage(const {'used_mins': 10}).total, 0);
    });
  });
}
