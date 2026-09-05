/// Screen one: pending "can I have more time" requests, with approve and deny.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/nestwatch_api.dart';
import 'notice.dart';
import 'polled_screen.dart';
import 'relative_time.dart';

/// The label on the control, quoted from the sentence that names it.
///
/// `curfew_note` ends *"Use \"Later bedtime tonight\" on the Curfew card to move bedtime
/// itself."* — so these four words are not this app's copy to choose. A parent reads the
/// server's instruction and then looks for the thing it named; a button called anything
/// else leaves them still looking.
///
/// Held as a constant so the coupling is greppable from both ends, and asserted against a
/// note captured off the wire in `test/later_bedtime_test.dart`. If nestwatch ever
/// rewrites that sentence, that test is where it surfaces — filed as the cross-repo half
/// of `M24`.
const String laterBedtimeLabel = 'Later bedtime tonight';

/// How much later, offered as choices rather than typed.
///
/// The endpoint validates against `timereq::MAX_REQUEST_MINUTES` (240) and `limits.json`
/// does not publish it, so a free-entry field would need this app to hold a copy of a
/// constant that lives in nestwatch's Rust — the fifth reader `M6` exists to delete. These
/// three sit well inside any plausible cap and need no copy at all. They are a product
/// choice, not a mirror of a limit, which is the same footing the time-code presets are on.
const List<int> laterBedtimeChoices = [15, 30, 60];

/// What to tell a parent once bedtime has moved.
///
/// Pure, and top-level, for the reason `screen_load.dart` and `refusal_lines.dart` give
/// about their own extractions: the interesting half is the branch, and a branch reachable
/// only through a widget is one a test has to stand up a screen to see. Here the branch is
/// [CurfewExtension.until] being null — a shape the server really can produce, because it
/// formats the time with `unwrap_or_default()` — and it is the branch a widget test is
/// least likely to exercise, since the ordinary payload has a time in it.
///
/// **Nothing here computes a time.** When that PC did not say when, this says how much
/// rather than inventing "now + 30". A phone adding minutes to its own clock would be a
/// fifth reader of a rule enforced against nestwatch's trusted clock, and a child who
/// changed the time zone is exactly the case that clock exists for.
String bedtimeConfirmation(CurfewExtension extension) => extension.until == null
    ? 'Bedtime moved back ${extension.minutes} minutes tonight.'
    : 'Bedtime is ${extension.until} tonight.';

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

  /// What that PC said about the last grant, when it said anything.
  ///
  /// Held rather than shown and forgotten. The grant it describes has already happened
  /// and the row it happened to is gone from the list by the time this renders, so there
  /// is nothing on screen that would otherwise carry the caveat.
  String? _curfewNote;

  /// What that PC said about the *extension* — the mirror of [_curfewNote].
  ///
  /// Held separately rather than reusing the field above, because they are opposite
  /// statements and only one can be true at a time. `curfew_note` says bedtime will
  /// swallow the minutes; `budget_note` says the screen-time budget will swallow the later
  /// bedtime. Showing both at once would leave a parent to work out which limit they are
  /// now up against, which is the confusion both sentences exist to prevent.
  String? _bedtimeNote;

  /// An extension in flight, so the control cannot be double-tapped.
  ///
  /// Unlike an approve, this endpoint is **not** idempotent: `extra_until` accumulates —
  /// each call adds its minutes to the previous extension rather than replacing it, which
  /// is deliberate on that side and means two taps really are two hours.
  bool _extending = false;

  Future<void> _decide(TimeRequest request, {required bool approve}) async {
    if (!_deciding.add(request.id)) return;
    // The set was already mutated by the guard above; this is the rebuild that greys
    // the buttons out. Saying so beats an empty setState that reads like a leftover.
    setState(() {});
    try {
      final decision = approve
          ? await widget.client.approveTimeRequest(request.id)
          : await widget.client.denyTimeRequest(request.id);
      if (!mounted) return;
      if (!decision.acted) {
        // 400: somebody already resolved it — the browser dashboard, or another phone.
        // An ordinary race, not something to put in front of a parent. Just re-read.
        _snack('That request had already been handled.');
      } else {
        _snack(
          approve
              ? 'Approved — ${request.minutes} more minutes today.'
              : 'Denied.',
        );
        // Only an approve moves this, and it replaces rather than accumulates.
        //
        // A grant that comes back with **no** note is positive evidence that nothing is
        // in the way right now, so it correctly clears a stale one. A deny carries no
        // note because it granted nothing — it says nothing about bedtime either way, so
        // letting it clear would throw away a caveat the parent may not have finished
        // reading. Two notes stacked would be worse than one: the parent would be left
        // working out which grant each was about.
        if (approve) {
          setState(() => _curfewNote = decision.curfewNote);
        }
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

    // Above the list, not inside it: the list is rebuilt from every poll and the note
    // belongs to an action, so anything that scrolled with the rows would be sorted or
    // scrolled away from the thing it is about.
    return Column(
      children: [
        if (_curfewNote case final note?) ...[
          Notice(
            note,
            tone: NoticeTone.warning,
            icon: Icons.bedtime,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            onDismiss: () => setState(() => _curfewNote = null),
          ),
          // Directly under the sentence that names it, and nowhere else in this app.
          // The note is what makes this control legible — it explains why bedtime is
          // about to take back the minutes just granted — and a button offering to move
          // bedtime with no such explanation beside it would be a Curfew card, which §5
          // deliberately left in the browser.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _extending ? null : _askLaterBedtime,
                icon: const Icon(Icons.nightlight_outlined, size: 18),
                label: Text(_extending ? 'Moving…' : laterBedtimeLabel),
              ),
            ),
          ),
        ] else if (_bedtimeNote case final note?)
          Notice(
            note,
            tone: NoticeTone.warning,
            icon: Icons.timelapse,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            onDismiss: () => setState(() => _bedtimeNote = null),
          ),
        Expanded(child: _list(requests)),
      ],
    );
  }

  /// Which extension, offered as choices. See [laterBedtimeChoices].
  Future<void> _askLaterBedtime() async {
    final minutes = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                laterBedtimeLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                'Moves bedtime itself, for tonight only. It goes back to normal '
                'tomorrow, and this is separate from screen time — moving bedtime '
                'does not add any minutes.',
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                children: [
                  for (final minutes in laterBedtimeChoices)
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(context).pop(minutes),
                      child: Text('$minutes min'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (minutes == null || !mounted) return;
    await _extendBedtime(minutes);
  }

  Future<void> _extendBedtime(int minutes) async {
    if (_extending) return;
    setState(() => _extending = true);
    try {
      final extension = await widget.client.extendCurfew(minutes);
      if (!mounted) return;
      setState(() {
        // The note that prompted this said bedtime would take the minutes back. It has
        // been acted on, so it has stopped being the current state of things — leaving it
        // up would argue with the confirmation below.
        _curfewNote = null;
        // And if the budget will swallow the later bedtime, that is the new true caveat.
        // Null clears rather than keeps: a fresh answer saying nothing is in the way is
        // positive evidence, the same reading `_curfewNote` takes from an approve.
        _bedtimeNote = extension.budgetNote;
      });
      _snack(bedtimeConfirmation(extension));
    } on NestwatchException catch (e) {
      if (!mounted) return;
      if (e.failure == NestwatchFailure.sessionExpired) {
        widget.onFailure(e);
        return;
      }
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _extending = false);
    }
  }

  Widget _list(List<TimeRequest> requests) {
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
