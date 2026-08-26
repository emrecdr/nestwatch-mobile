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
