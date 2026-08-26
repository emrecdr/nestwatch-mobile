/// The payloads the three screens read.
///
/// Field names and nullability were taken off the wire against nestwatch 0.3.0, not
/// inferred from the Rust types — `remaining_mins` is `null` under an unlimited budget,
/// which a naive `as int` would have crashed on.
library;

/// One pending "can I have more time" request.
///
/// The queue is capped at 5 server-side (`MAX_PENDING`, nestwatch `src/timereq.rs`), so
/// this list never paginates. Newest first, as the server returns it.
class TimeRequest {
  final String id;

  /// ISO-8601 UTC, as a string. Kept as sent and parsed for display only: the server is
  /// the clock of record here, and a phone in another timezone must not silently
  /// reinterpret it.
  final String ts;
  final int minutes;
  final String reason;

  const TimeRequest({
    required this.id,
    required this.ts,
    required this.minutes,
    required this.reason,
  });

  static TimeRequest fromJson(Map<String, dynamic> json) => TimeRequest(
    id: json['id'] as String,
    ts: json['ts'] as String? ?? '',
    minutes: (json['minutes'] as num?)?.toInt() ?? 0,
    reason: (json['reason'] as String? ?? '').trim(),
  );

  DateTime? get submittedAt => DateTime.tryParse(ts)?.toLocal();
}

/// One row of "what was actually used", shared by `per_app`, `groups`, `focused`
/// and `pages` — which use two different key spellings for the same idea.
class UsageRow {
  final String name;
  final int minutes;

  /// `null` where the row carries no limit (focus and page rows do not).
  final int? limitMinutes;

  const UsageRow({
    required this.name,
    required this.minutes,
    this.limitMinutes,
  });

  /// `per_app` and `groups` send `{name, used_mins, limit_mins}`; `focused` and `pages`
  /// send `{name, minutes}`. One reader, because they render identically.
  static UsageRow fromJson(Map<String, dynamic> json) => UsageRow(
    name: json['name'] as String? ?? '',
    minutes: ((json['used_mins'] ?? json['minutes']) as num?)?.toInt() ?? 0,
    limitMinutes: (json['limit_mins'] as num?)?.toInt(),
  );
}

/// `GET /api/usage/today` (nestwatch `rules::today_summary`).
class UsageToday {
  final String? day;
  final bool enabled;
  final int budgetMinutes;
  final int usedMinutes;

  /// `null` when the budget is unlimited — not zero. Seen on the wire.
  final int? remainingMinutes;

  final int extraMinutes;

  /// Seconds since an enforcer last reached a tick, or `null`.
  ///
  /// Load-bearing, and the reason is in nestwatch's own comment: it is "the only signal
  /// that distinguishes a dead enforcer from a quiet day, since both otherwise show zero
  /// minutes used". A usage screen that renders `used_mins: 0` without it is telling a
  /// parent their child was off the computer when nothing may have been watching.
  final int? enforcerAgeSeconds;

  /// The server's own verdict that focus data is missing rather than empty: set when at
  /// least [_focusEvidenceSeconds] of use accrued with no foreground data at all.
  ///
  /// nestwatch's comment: "rendering silence as zero is the failure this codebase has
  /// already fixed twice." Not repeating it here.
  final bool focusMissing;

  final List<UsageRow> perApp;
  final List<UsageRow> groups;
  final List<UsageRow> focused;
  final List<UsageRow> pages;

  const UsageToday({
    required this.day,
    required this.enabled,
    required this.budgetMinutes,
    required this.usedMinutes,
    required this.remainingMinutes,
    required this.extraMinutes,
    required this.enforcerAgeSeconds,
    required this.focusMissing,
    required this.perApp,
    required this.groups,
    required this.focused,
    required this.pages,
  });

  static List<UsageRow> _rows(Object? raw) => (raw as List? ?? [])
      .whereType<Map<String, dynamic>>()
      .map(UsageRow.fromJson)
      .toList();

  static UsageToday fromJson(Map<String, dynamic> json) => UsageToday(
    day: json['day'] as String?,
    enabled: json['enabled'] as bool? ?? true,
    budgetMinutes: (json['budget_mins'] as num?)?.toInt() ?? 0,
    usedMinutes: (json['used_mins'] as num?)?.toInt() ?? 0,
    remainingMinutes: (json['remaining_mins'] as num?)?.toInt(),
    extraMinutes: (json['extra_mins'] as num?)?.toInt() ?? 0,
    enforcerAgeSeconds: (json['enforcer_age_secs'] as num?)?.toInt(),
    focusMissing: json['focus_missing'] as bool? ?? false,
    perApp: _rows(json['per_app']),
    groups: _rows(json['groups']),
    focused: _rows(json['focused']),
    pages: _rows(json['pages']),
  );

  /// An unlimited budget reports `budget_mins: 0` and `remaining_mins: null`.
  bool get isUnlimited => remainingMinutes == null;

  /// How stale the enforcer heartbeat may get before it stops meaning "quiet day".
  ///
  /// The dashboard's own threshold is not exported, so this is the app's, chosen to be
  /// several times the 30-second tick rather than tuned: the point is to catch a dead
  /// enforcer, not to report jitter.
  static const Duration enforcerStaleAfter = Duration(minutes: 5);

  /// True when the heartbeat is old enough that "0 minutes used" may mean "nothing was
  /// watching" rather than "nothing happened".
  bool get enforcementMayBeStopped {
    final age = enforcerAgeSeconds;
    if (age == null) return true;
    return age > enforcerStaleAfter.inSeconds;
  }
}

/// An issued, not-yet-redeemed time code (nestwatch `timecode::ActiveCode`).
///
/// The parent mints one before leaving, writes it down, and the child types it into the
/// LAN page to add the minutes to today's budget — **no parent action and no internet
/// needed at redemption time**. `src/timecode.rs` names the case: "Useful when the
/// parent is away (leave a code) or the network is down."
class TimeCode {
  /// 6 characters of Crockford base32, from the same generator as pairing tokens.
  ///
  /// The length is nestwatch's to choose and is **not enforced here**: this app displays
  /// codes, it never mints or validates them, so hard-coding a length would only add a
  /// place to break the next time it changes. `tool/prove_timecodes.dart` pins the
  /// agreed value against a live server, which is where a disagreement should surface.
  ///
  /// Short enough to read aloud, and safe because of the throttle rather than the
  /// length: 32^6 is about 1.07 billion, and `/redeem-code` is LAN-gated and capped at
  /// 5 attempts per minute per IP.
  ///
  /// A secret: it grants screen time to whoever types it. nestwatch deliberately keeps
  /// it out of the audit log for that reason ("The code itself is a secret (it grants
  /// time), so it is NOT written to the audit log") — this app should be no looser.
  final String code;

  /// ISO-8601 UTC, as sent.
  final String ts;
  final int minutes;

  const TimeCode({required this.code, required this.ts, required this.minutes});

  static TimeCode fromJson(Map<String, dynamic> json) => TimeCode(
    code: json['code'] as String? ?? '',
    ts: json['ts'] as String? ?? '',
    minutes: (json['minutes'] as num?)?.toInt() ?? 0,
  );

  DateTime? get issuedAt => DateTime.tryParse(ts)?.toLocal();

  /// Never render the code by accident. Showing it is always a deliberate act.
  @override
  String toString() => 'TimeCode($minutes min, code redacted)';
}

/// Limits from nestwatch `src/timecode.rs`, mirrored so the UI can refuse locally
/// instead of round-tripping to a 400.
/// What that PC does to a phone guessing the control password.
///
/// Mirrors `LoginLimiter::default` in nestwatch `src/auth.rs` — five wrong tries, then
/// that IP is refused for the lockout. A correct password clears the state immediately,
/// which is why `tool/prove_login.dart` logs in properly before it tries a wrong one.
///
/// These exist as constants because the number used to live only inside an English
/// sentence — "stopped accepting tries for a minute" — which is a copy of a server rule
/// with nothing to grep and nothing to pin. `tool/check_golden.sh` now compares them
/// against that PC's source, which it cannot do to prose.
class LoginLimits {
  static const int maxAttempts = 5;

  /// Seconds, and the [Duration] built over it — rather than the other way round.
  ///
  /// The plain number is what nestwatch's `LOGIN_LOCKOUT` holds and what
  /// `tool/check_golden.sh` compares, and it reads it with the same one-line reader it
  /// uses for every other mirrored constant. Written only as `Duration(seconds: 60)` it
  /// needed a grep of its own, and a bespoke reader for one value is a reader that goes
  /// stale on its own schedule.
  static const int lockoutSeconds = 60;
  static const Duration lockout = Duration(seconds: lockoutSeconds);

  /// The lockout as a parent would say it, for a message they read while locked out.
  ///
  /// [of] is injectable so the branches can be tested — the same reason `ago` takes a
  /// clock. Without it the only reachable case is whatever [lockout] happens to be, and
  /// the other two would be written but never run.
  static String lockoutInWords([Duration? of]) {
    final seconds = (of ?? lockout).inSeconds;
    if (seconds == 60) return 'a minute';
    if (seconds % 60 == 0) return '${(of ?? lockout).inMinutes} minutes';
    return '$seconds seconds';
  }
}

class TimeCodeLimits {
  /// `MAX_CODE_MINUTES`.
  static const int maxMinutes = 240;

  /// `MAX_ACTIVE_CODES` — the cap on outstanding, unredeemed codes.
  static const int maxActive = 50;

  static bool isValidMinutes(int minutes) =>
      minutes > 0 && minutes <= maxMinutes;
}
