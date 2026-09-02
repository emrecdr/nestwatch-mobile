/// When a frame arrived, said once so both surfaces cannot disagree.
///
/// ## The defect this exists to remove
///
/// The screenshot screen told a sighted parent and a screen-reader user two different
/// things, and only one of them could go false. The visible line read
/// *"Frame from 14:32:07"* — an absolute time, which stays true however long it sits
/// there. The `semanticLabel` on the image was built from `ago()`, a **relative** time
/// computed once at build.
///
/// That screen is the only one in the app whose poller can be stopped while its content
/// stays on screen: the other `ago()` callers repoll every 60 s, so they drift by at most
/// a minute. Here, `_frameAt` is set to `DateTime.now()` immediately before the rebuild,
/// so the label always evaluated to "just now" — and then nothing rebuilt it. A parent
/// using a screen reader could stop the live view, come back ten minutes later, and be
/// told the picture was current.
///
/// ## Why absolute, rather than a ticker
///
/// Adding a timer to refresh a relative label would keep the drift and pay for it in
/// wakeups on a screen whose whole design is about not asking that PC for things nobody
/// is looking at. An absolute time makes no claim about *now*, so there is nothing to go
/// stale and nothing to refresh.
///
/// It also puts the app back on the usual convention rather than inverting it. The
/// published guidance is relative for the visible label — easier to read — with the
/// absolute time exposed to assistive technology, because that is the half that cannot be
/// kept current without live updates. This screen had those exactly the wrong way round.
///
/// Both strings now come from one function, so the spoken and the visible answer are the
/// same fact rather than two renderings that agree until one of them is edited.
library;

/// `HH:MM:SS` on a 24-hour clock, in the phone's local time.
///
/// Seconds are kept because this is the one place in the app where a few seconds is the
/// difference between a live view and a stopped one.
String frameClock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}:'
    '${at.second.toString().padLeft(2, '0')}';

/// What a screen reader announces for the picture itself.
///
/// Null before the first frame: there is a picture of nothing, and saying "taken at" about
/// it would be worse than saying less.
String frameLabel(DateTime? frameAt) => frameAt == null
    ? 'A picture of the screen on that PC.'
    : 'A picture of the screen on that PC, taken at ${frameClock(frameAt)}.';
