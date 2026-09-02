/// The sentences for "Refused today", kept out of the widget so the rules can be tested.
///
/// ## Why the wording is borrowed rather than written
///
/// nestwatch sends **counts, not sentences** — `refused` and `refused_total`, and nothing
/// else. So a client has to compose the prose, and the dashboard already composes some.
/// Two surfaces inventing separate vocabularies for the same three facts is how a parent
/// ends up reading "clock change ignored" on one screen and something subtly different on
/// the other, and then wondering whether they are the same event. These match
/// `refusedRows()` in nestwatch `assets/app.js` word for word.
///
/// The one deliberate difference is the count's position. The dashboard puts it in a badge
/// beside the sentence; a phone row is narrower than that layout wants, so it leads the
/// line instead. The words are unchanged.
///
/// ## The constraint that matters more than the wording
///
/// **These say what the tool did, never what anyone meant by it.** A family that genuinely
/// crossed a time zone produces exactly the same count as a clock moved on purpose, and
/// none of these sentences pretends to tell them apart. That is what makes the card safe
/// to show the child as well as the parent, which nestwatch records as the arrangement
/// research on monitoring finds survives contact with a teenager — an accusation is the
/// one that does not.
///
/// `refusal_lines_test.dart` holds that constraint as a test rather than as this comment,
/// because a comment cannot fail.
library;

import '../api/models.dart';

/// The heading, matching the dashboard's card title.
const String refusalsTitle = 'Refused today';

/// The line under it. Says the limits held, because that is the part a parent needs and
/// the part a bare list of counts does not carry.
const String refusalsIntro =
    'Things this PC tried that Nestwatch declined. The limits held; nothing here '
    'needs fixing. Counted since midnight.';

/// One sentence per non-zero count, in the dashboard's order.
///
/// A zero produces no line at all rather than a greyed one: the section only appears when
/// something is non-zero, and "0 clock changes ignored" inside it would be an answer to a
/// question nobody asked.
List<String> refusalLines(Refusals refused) => [
  if (refused.clockChanges > 0)
    '${refused.clockChanges} '
        '${_plural(refused.clockChanges, 'clock change ignored', 'clock changes ignored')}'
        ' — screen time and bedtime kept using the trusted time',
  if (refused.dayResets > 0)
    '${refused.dayResets} '
        '${_plural(refused.dayResets, 'attempt to start the day over refused', 'attempts to start the day over refused')}'
        " — today's total stood",
  if (refused.shutdownCancels > 0)
    '${refused.shutdownCancels} '
        '${_plural(refused.shutdownCancels, 'shutdown cancelled on the PC', 'shutdowns cancelled on the PC')}'
        ' — re-issued straight away, without a fresh countdown',
];

/// Mirrors `plural(n, one, many)` in nestwatch `assets/app.js`.
String _plural(int n, String one, String many) => n == 1 ? one : many;
