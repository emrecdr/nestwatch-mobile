/// Does that PC speak the contract this app was built against?
///
/// PLAN §5 step 2 says `GET /session` "doubles as the pin probe and gives `version` for
/// compatibility checks before anything secret is sent". The probe was built; the check
/// was not. `version` was parsed into [SessionInfo] and used nowhere, which meant a PC
/// running a nestwatch older than this app expects showed up as a parse failure on some
/// screen, with no sentence anywhere saying the two had disagreed.
///
/// ## What "the contract" is, exactly
///
/// It is not a guess. `test/golden/` holds nestwatch's own serde output, vendored, and
/// `test/models_golden_test.dart` asserts every shape this app parses against those
/// files. [testedAgainst] is the version those files were captured from — so the claim
/// this makes is narrow and true: *these* JSON shapes were checked against *that*
/// nestwatch. `tool/check_golden.sh` compares it to the sibling checkout and shouts when
/// it cannot read one, because a version check that stops checking is the failure mode
/// this repo keeps finding in itself.
///
/// ## Three outcomes
///
/// Agreed, disagreed, and **could not tell** — the last being the one a two-valued check
/// would quietly fold into "fine". A PC that reports no version at all is not a PC that
/// matches.
library;

/// Which way the two versions disagree, if they do.
enum ContractAgreement {
  /// Same major and minor. Patch releases do not move the wire format.
  agreed,

  /// That PC is behind this app: a shape this app parses may not exist there yet.
  serverOlder,

  /// That PC is ahead: it may send fields and endpoints this app has never seen.
  serverNewer,

  /// No version to compare. Not the same as agreement, and never rendered as silence.
  unreadable,
}

/// The comparison itself, with the sentence a parent would need.
class ContractCheck {
  /// The nestwatch release `test/golden/` was captured from.
  ///
  /// Bump this **with** the golden files, never on its own — it is a statement about what
  /// those files came from, and the two moving separately is how a version check starts
  /// lying. `tool/check_golden.sh` compares it against the sibling checkout's `Cargo.toml`.
  static const String testedAgainst = '0.4.0';

  final ContractAgreement agreement;

  /// What that PC said, verbatim, so a parent reading a warning can repeat it back.
  final String reported;

  const ContractCheck._(this.agreement, this.reported);

  /// Compare a `version` string from `GET /session` against [testedAgainst].
  ///
  /// Only major and minor are compared. nestwatch is pre-1.0, where minor carries the
  /// breaking changes and patch carries fixes; comparing patch would put a notice on a
  /// parent's screen for a release that cannot have changed anything this app reads.
  factory ContractCheck.of(String reported) {
    final theirs = _parse(reported);
    final ours = _parse(testedAgainst);
    if (theirs == null || ours == null) {
      return ContractCheck._(ContractAgreement.unreadable, reported);
    }
    final theirRank = theirs.$1 * 1000 + theirs.$2;
    final ourRank = ours.$1 * 1000 + ours.$2;
    if (theirRank == ourRank) {
      return ContractCheck._(ContractAgreement.agreed, reported);
    }
    return ContractCheck._(
      theirRank < ourRank
          ? ContractAgreement.serverOlder
          : ContractAgreement.serverNewer,
      reported,
    );
  }

  /// `null` when there is nothing to say — the only case that draws no notice.
  ///
  /// Every other branch produces a sentence, including the one where the check failed.
  /// The wording names which side is behind, because "versions differ" leaves a parent
  /// with nothing to do and the actions are opposite: update that PC, or update this app.
  String? get message => switch (agreement) {
    ContractAgreement.agreed => null,
    ContractAgreement.serverOlder =>
      'That PC is running nestwatch $reported, and this app was built against '
          '$testedAgainst. Screens may be empty or fail to load. Updating nestwatch '
          'on that PC is the fix — this app cannot work around it.',
    ContractAgreement.serverNewer =>
      'That PC is running nestwatch $reported; this app was checked against '
          '$testedAgainst. Newer is usually fine. If something here looks wrong, it '
          'is this app that is behind, not that PC.',
    ContractAgreement.unreadable =>
      'That PC did not say which version of nestwatch it is running, so this app '
          'could not check whether the two agree. Everything below may be correct — '
          'it has not been confirmed.',
  };

  /// Whether this is worth alarming a parent over, as opposed to telling them.
  ///
  /// Only [ContractAgreement.serverOlder] is: it is the case where a screen is going to
  /// break and the parent holds the fix. Being *ahead* of this app, or being unable to
  /// tell, are both worth saying and neither is worth a warning colour.
  bool get isWarning => agreement == ContractAgreement.serverOlder;

  /// `major.minor`, or null for anything that is not two dotted numbers.
  ///
  /// `SessionInfo.version` falls back to the literal string `unknown` when the field is
  /// absent, and that lands here as null rather than as a special case — an unparseable
  /// version and a missing one leave a parent in exactly the same position.
  static (int, int)? _parse(String raw) {
    final parts = raw.trim().split('.');
    if (parts.length < 2) return null;
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    if (major == null || minor == null) return null;
    return (major, minor);
  }
}
