/// Screen one: pending "can I have more time" requests, with approve and deny.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/nestwatch_api.dart';
import 'polled_screen.dart';
import 'relative_time.dart';

class TimeRequestsScreen extends PolledScreen {
  final NestwatchClient client;
  @override
  final bool visible;
  @override
  final void Function(NestwatchException) onFailure;
  @override
  final Listenable? invalidatedBy;

  const TimeRequestsScreen({
    super.key,
    required this.client,
    required this.visible,
    required this.onFailure,
    this.invalidatedBy,
  });

  @override
  State<TimeRequestsScreen> createState() => _TimeRequestsScreenState();
}

class _TimeRequestsScreenState extends State<TimeRequestsScreen>
    with PolledScreenState<TimeRequestsScreen, List<TimeRequest>> {
  @override
  Future<List<TimeRequest>> fetch() => widget.client.timeRequests();

  /// Ids with a decision in flight.
  ///
  /// PLAN.md §5 asks for a debounce even though the server is safe, and nestwatch's own
  /// comment says why the server had to be made safe: "six concurrent approvals of one
  /// request all returned `Some` — so a parent double-tapping Approve on a phone granted
  /// the minutes twice". The gate fixed the grant; this stops the second tap ever being
  /// sent, which also stops the 400 it would come back with.
  final _deciding = <String>{};

  Future<void> _decide(TimeRequest request, {required bool approve}) async {
    if (!_deciding.add(request.id)) return;
    // The set was already mutated by the guard above; this is the rebuild that greys
    // the buttons out. Saying so beats an empty setState that reads like a leftover.
    setState(() {});
    try {
      final acted = approve
          ? await widget.client.approveTimeRequest(request.id)
          : await widget.client.denyTimeRequest(request.id);
      if (!mounted) return;
      if (!acted) {
        // 400: somebody already resolved it — the browser dashboard, or another phone.
        // An ordinary race, not something to put in front of a parent. Just re-read.
        _snack('That request had already been handled.');
      } else {
        _snack(
          approve
              ? 'Approved — ${request.minutes} more minutes today.'
              : 'Denied.',
        );
      }
    } on NestwatchException catch (e) {
      if (!mounted) return;
      if (e.failure == NestwatchFailure.sessionExpired) {
        widget.onFailure(e);
        return;
      }
      _snack(e.message);
    } finally {
      _deciding.remove(request.id);
      if (mounted) await load();
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final requests = data;
    if (requests == null) return waitingPane();

    return RefreshIndicator(
      onRefresh: load,
      child: requests.isEmpty
          ? ListView(
              // Must scroll even when empty, or pull-to-refresh has nothing to grab.
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Icon(
                  Icons.check_circle_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 12),
                const Center(child: Text('Nothing waiting.')),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: requests.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) => _card(context, requests[i]),
            ),
    );
  }

  Widget _card(BuildContext context, TimeRequest request) {
    final busy = _deciding.contains(request.id);
    final at = request.submittedAt;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${request.minutes} more minutes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (at != null)
                  Text(ago(at), style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            if (request.reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(request.reason),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  // Labelled with the request it answers. Read in order a screen reader
                  // already gives the context — the minutes and the reason are announced
                  // above these buttons — but jumping control to control is how people
                  // actually move through a list, and there "Approve, Approve, Approve"
                  // names nothing. The visible text stays short; only the spoken one grows.
                  child: Semantics(
                    label: 'Approve ${request.minutes} more minutes',
                    button: true,
                    child: FilledButton(
                      onPressed: busy
                          ? null
                          : () => _decide(request, approve: true),
                      child: Text(busy ? '…' : 'Approve'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    label: 'Deny ${request.minutes} more minutes',
                    button: true,
                    child: OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => _decide(request, approve: false),
                      child: const Text('Deny'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
