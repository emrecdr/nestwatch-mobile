/// Screen two: what today looks like.
///
/// ## The thing this screen must not do
///
/// nestwatch reports `used_mins: 0` both when a child was nowhere near the computer and
/// when nothing was watching. Two fields exist purely to tell those apart, and both come
/// with a comment in `rules.rs` explaining that conflating them is a bug the codebase has
/// already had:
///
///   * `enforcer_age_secs` — "the only signal that distinguishes a dead enforcer from a
///     quiet day, since both otherwise show zero minutes used";
///   * `focus_missing` — "rendering silence as zero is the failure this codebase has
///     already fixed twice."
///
/// A phone screen showing a reassuring "0 minutes" over a dead enforcer is worse than no
/// screen, so both are surfaced above the numbers they qualify.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/nestwatch_api.dart';
import 'polled_screen.dart';

class UsageScreen extends PolledScreen {
  final NestwatchClient client;
  @override
  final bool visible;
  @override
  final void Function(NestwatchException) onFailure;

  const UsageScreen({
    super.key,
    required this.client,
    required this.visible,
    required this.onFailure,
  });

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen>
    with PolledScreenState<UsageScreen, UsageToday> {
  @override
  Future<UsageToday> fetch() => widget.client.usageToday();

  @override
  Widget build(BuildContext context) {
    final usage = data;
    if (usage == null) return waitingPane();

    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // Caveats first: they change what the numbers below mean.
          if (usage.enforcementMayBeStopped) _enforcerWarning(context, usage),
          if (!usage.enabled) _disabledNotice(context),
          _headline(context, usage),
          if (usage.extraMinutes > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Includes ${usage.extraMinutes} extra minutes granted today.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          _section(context, 'Apps with limits', usage.perApp),
          _section(context, 'Groups', usage.groups),
          if (usage.focusMissing) _focusMissingNotice(context),
          _section(context, 'Most used', usage.focused),
          _section(context, 'Pages', usage.pages),
        ],
      ),
    );
  }

  Widget _headline(BuildContext context, UsageToday usage) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${usage.usedMinutes} min used today',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              usage.isUnlimited
                  // remaining_mins is null under an unlimited budget — not zero.
                  ? 'No daily limit set.'
                  : '${usage.remainingMinutes} min left of '
                        '${usage.budgetMinutes} min',
              style: theme.textTheme.bodyLarge,
            ),
            if (usage.day != null) ...[
              const SizedBox(height: 4),
              Text(usage.day!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  /// "Nothing happened" and "nothing was watching" look identical without this.
  Widget _enforcerWarning(BuildContext context, UsageToday usage) {
    final age = usage.enforcerAgeSeconds;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              age == null
                  ? 'That PC did not report whether screen-time enforcement is running. '
                        'The figures below may not mean anything.'
                  : 'Screen-time enforcement last reported ${_age(age)} ago. If that '
                        'keeps growing, nothing is being measured or enforced — and a '
                        'low number below would mean nobody was watching, not that '
                        'nobody was using the PC.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _disabledNotice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Screen-time rules are switched off on that PC. Time is still measured, but '
        'nothing is enforced.',
        style: TextStyle(color: scheme.onTertiaryContainer),
      ),
    );
  }

  Widget _focusMissingNotice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'The PC was in use, but nothing recorded which apps were in front. The list '
        'below is empty because the watcher is not reporting — not because nothing '
        'was used.',
        style: TextStyle(color: scheme.onTertiaryContainer),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<UsageRow> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(child: Text(row.name)),
                Text(
                  row.limitMinutes == null
                      ? '${row.minutes} min'
                      : '${row.minutes} / ${row.limitMinutes} min',
                  style: TextStyle(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color:
                        row.limitMinutes != null &&
                            row.minutes >= row.limitMinutes!
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _age(int seconds) {
    if (seconds < 120) return '$seconds seconds';
    if (seconds < 7200) return '${seconds ~/ 60} minutes';
    return '${seconds ~/ 3600} hours';
  }
}
