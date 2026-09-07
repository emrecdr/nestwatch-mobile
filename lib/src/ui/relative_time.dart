/// How long ago, in the words a parent would use.
///
/// Two screens had this character for character: the time a request was submitted, and
/// the time a code was made. Wording is the whole job of it — "just now" and "3 h ago"
/// are a decision about how precise to sound, not a calculation — so two copies meant two
/// places to change and one to forget.
library;

/// [now] is injectable so the boundaries can be tested. Callers pass only [at].
String ago(DateTime at, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// When a signed-in device was last active, at the only precision that number has.
///
/// **Separate from [ago], and it must stay separate.** `ago` is for an instant the server
/// recorded when it happened — a request submitted, a code minted. `last_seen` is nothing
/// of the sort: nestwatch derives it as `expires - SESSION_IDLE_DAYS`, so it is the last
/// time the session was *saved*, and the sliding expiry only saves every five days. The
/// number is therefore accurate to within about a working week, and their own comment says
/// what may honestly be built on it — *"'Active this week' is what the card can honestly
/// say, and it is enough to tell a live phone from one retired in August."*
///
/// Running it through `ago` would render "3 d ago" against a figure that cannot support a
/// day, which is the `used_mins: 0` failure in a different costume: a true-looking number
/// with a precision nobody measured. So the buckets below are deliberately wider than the
/// data, and the widest one names a month rather than counting.
String lastSeenPhrase(DateTime lastSeen, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(lastSeen);
  // Negative is reachable and is not an error: `expires` moves forward on a refresh, so a
  // session saved moments ago can compute a `last_seen` a hair into the future against a
  // phone clock that disagrees. It reads as current, because it is.
  if (d.inDays < 7) return 'Active this week';
  if (d.inDays < 14) return 'Active last week';
  if (d.inDays < 31) return 'Active this month';
  return 'Not used in over a month';
}
