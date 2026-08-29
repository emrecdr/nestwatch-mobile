/// The notifications setting.
///
/// The copy here is the point. PLAN.md §5 settles on an honest promise —
/// *"you'll hear about a request within about fifteen minutes"* — because WorkManager's
/// floor is 15 minutes and anything shorter is silently clamped. Implying immediacy would
/// be a promise the platform declines to keep, and the parent would find out by missing
/// something.
library;

import 'package:flutter/material.dart';

import '../background/background_poll.dart';
import '../background/notifications.dart';
import '../background/watch_now.dart';
import 'background_promise.dart';

class NotificationsSheet extends StatefulWidget {
  final String authority;
  const NotificationsSheet({super.key, required this.authority});

  @override
  State<NotificationsSheet> createState() => _NotificationsSheetState();
}

class _NotificationsSheetState extends State<NotificationsSheet> {
  bool? _enabled;
  bool _watching = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    initWatchService();
    _refresh();
  }

  Future<void> _refresh() async {
    final on = await notificationsEnabled();
    final watching = await isWatching();
    if (mounted) {
      setState(() {
        _enabled = on;
        _watching = watching;
      });
    }
  }

  Future<void> _toggleWatch(bool wanted) async {
    setState(() => _busy = true);
    try {
      if (!wanted) {
        await stopWatching();
      } else {
        // The persistent notification is the service's; posting it needs the same
        // permission as the request alerts, so ask here too rather than starting a
        // service whose notification Android will not show.
        if (!await notificationsEnabled() &&
            !await requestNotificationPermission()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Watching needs notifications switched on.'),
              ),
            );
          }
          return;
        }
        await startWatching(widget.authority);
      }
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool wanted) async {
    setState(() => _busy = true);
    try {
      if (!wanted) {
        await disableBackgroundPolling();
        if (mounted) setState(() => _enabled = false);
        return;
      }

      // Android 13+ will not post anything until this is granted, so ask before
      // scheduling — a poll that runs and tells nobody looks exactly like a poll that
      // never ran.
      final granted = await requestNotificationPermission();
      if (!granted) {
        if (mounted) {
          setState(() => _enabled = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Notifications are switched off for Nestwatch in Android settings.',
              ),
            ),
          );
        }
        return;
      }
      await enableBackgroundPolling();
      if (mounted) setState(() => _enabled = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('Notifications', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled ?? false,
            onChanged: _busy || _enabled == null ? null : _toggle,
            title: const Text('Tell me about time requests'),
            subtitle: Text(backgroundCadenceLine(pollInterval.inMinutes)),
          ),
          const SizedBox(height: 12),
          Text(
            backgroundCaveat(pollInterval.inMinutes),
            style: theme.textTheme.bodySmall,
          ),
          // No "watch now" on iOS. It is a dataSync foreground service, and iOS has no
          // equivalent — an app cannot poll for half an hour from the background because
          // the parent asked it to. A switch that silently does nothing is worse than an
          // absent one, and is the failure this codebase keeps finding elsewhere.
          if (watchNowIsPossible) ...[
            const Divider(height: 36),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _watching,
              onChanged: _busy ? null : _toggleWatch,
              title: const Text('Watch now'),
              subtitle: Text(
                'Check every ${watchPollInterval.inSeconds} seconds for the next '
                '${watchSessionLimit.inMinutes} minutes.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'For when you are waiting on an answer. It shows a notification while it '
              'runs and stops on its own — Android allows this kind of check a total of '
              'six hours a day, so leaving it on would use up the allowance and leave '
              'none for later.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Nothing about your child leaves your home network. The check runs on this '
            'phone and talks only to that PC.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
