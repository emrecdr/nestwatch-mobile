/// Screen four: leave a code for while you are out.
///
/// PLAN.md §7 says away-from-home *notification* is impossible, and that is true — push
/// needs the server to make outbound connections, which the whole design forbids. But
/// nestwatch already answers the underlying problem, and until now the app did not
/// surface it: the parent mints a single-use code before leaving, the child types it into
/// the LAN page, and the minutes land in today's budget with **no parent action and no
/// internet at redemption time**. `src/timecode.rs` names the case exactly — "Useful when
/// the parent is away (leave a code) or the network is down."
///
/// ## Why a fourth screen, when §5 says three
///
/// §5 keeps rules, routines and curfew in the browser because they are configuration:
/// done rarely, at a desk, and each one added is a second interface to keep in step with
/// 24 routes forever. That test is about *where you are* when you need the thing, and it
/// is why this one belongs here and those do not: a time code is used **because** you are
/// away from the browser. The phone is not a worse version of the dashboard for this
/// task; it is the only thing in reach.
///
/// ## The code is a secret
///
/// It grants screen time to whoever types it. nestwatch keeps it out of the audit log for
/// that reason — "The code itself is a secret (it grants time), so it is NOT written to
/// the audit log" — so this screen is no looser: codes are hidden until deliberately
/// revealed, and never rendered by an accidental `toString`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../api/nestwatch_api.dart';
import 'poller.dart';

class TimeCodesScreen extends StatefulWidget {
  final NestwatchClient client;
  final bool visible;
  final void Function(NestwatchException) onFailure;

  const TimeCodesScreen({
    super.key,
    required this.client,
    required this.visible,
    required this.onFailure,
  });

  @override
  State<TimeCodesScreen> createState() => _TimeCodesScreenState();
}

class _TimeCodesScreenState extends State<TimeCodesScreen> {
  late final Poller _poller = Poller(interval: dataCadence, tick: _load);

  List<TimeCode>? _codes;
  String? _error;
  bool _minting = false;

  /// Codes the parent has chosen to reveal, by code value.
  ///
  /// Deliberately not persisted and not defaulted to shown: a screen that displays every
  /// code at once turns a shoulder-glance into a week of extra screen time.
  final _revealed = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.visible) _poller.start();
  }

  @override
  void didUpdateWidget(TimeCodesScreen old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    widget.visible ? _poller.start() : _poller.stop();
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final codes = await widget.client.timeCodes();
      if (!mounted) return;
      setState(() {
        _codes = codes;
        _error = null;
        // Forget reveals for codes that have since been redeemed.
        _revealed.retainWhere((c) => codes.any((k) => k.code == c));
      });
    } on NestwatchException catch (e) {
      if (!mounted) return;
      if (e.failure == NestwatchFailure.sessionExpired) {
        widget.onFailure(e);
        return;
      }
      setState(() => _error = e.message);
    }
  }

  Future<void> _mint(int minutes) async {
    if (_minting) return;
    setState(() => _minting = true);
    try {
      final code = await widget.client.issueTimeCode(minutes);
      if (!mounted) return;
      // Reveal the one just made: the parent asked for it and has to write it down.
      _revealed.add(code.code);
      await _load();
      if (mounted) _showCode(code);
    } on NestwatchException catch (e) {
      if (!mounted) return;
      if (e.failure == NestwatchFailure.sessionExpired) {
        widget.onFailure(e);
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _minting = false);
    }
  }

  void _showCode(TimeCode code) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${code.minutes} minutes'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            code.code,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 30,
              letterSpacing: 5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Write this down and leave it where you mean to. It works once, adds the '
            'minutes to that day\'s budget, and needs no internet — so it works while '
            'you are out and while your home network is down.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: code.code));
            Navigator.of(context).pop();
          },
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final codes = _codes;
    if (codes == null) {
      return _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          : const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text('Leave a code', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Your child types it on the ask page to add the minutes themselves. It '
            'works once, and needs neither you nor the internet.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              for (final minutes in const [15, 30, 60])
                FilledButton.tonal(
                  onPressed:
                      _minting || codes.length >= TimeCodeLimits.maxActive
                      ? null
                      : () => _mint(minutes),
                  child: Text('$minutes min'),
                ),
              OutlinedButton(
                onPressed: _minting || codes.length >= TimeCodeLimits.maxActive
                    ? null
                    : _askForMinutes,
                child: const Text('Other…'),
              ),
            ],
          ),
          if (codes.length >= TimeCodeLimits.maxActive) ...[
            const SizedBox(height: 10),
            Text(
              'That PC is holding the most codes it will (${TimeCodeLimits.maxActive}). '
              'Use or hand out some of these before making another.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const Divider(height: 36),
          Text(
            codes.isEmpty
                ? 'Nothing waiting to be used.'
                : '${codes.length} not used yet',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          for (final code in codes) _codeTile(context, code),
        ],
      ),
    );
  }

  Widget _codeTile(BuildContext context, TimeCode code) {
    final shown = _revealed.contains(code.code);
    final at = code.issuedAt;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(
          // Hidden by default. Revealing is a deliberate act, because anyone who reads
          // the code can spend it.
          shown ? code.code : '••••••••',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 20,
            letterSpacing: 4,
          ),
        ),
        subtitle: Text(
          at == null
              ? '${code.minutes} minutes'
              : '${code.minutes} minutes · made ${_ago(at)}',
        ),
        trailing: IconButton(
          tooltip: shown ? 'Hide' : 'Show',
          icon: Icon(shown ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(
            () =>
                shown ? _revealed.remove(code.code) : _revealed.add(code.code),
          ),
        ),
        onTap: shown ? () => _showCode(code) : null,
      ),
    );
  }

  Future<void> _askForMinutes() async {
    final controller = TextEditingController();
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('How many minutes?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            helperText: '1 to ${TimeCodeLimits.maxMinutes}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(controller.text.trim())),
            child: const Text('Make it'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (minutes == null || !mounted) return;
    if (!TimeCodeLimits.isValidMinutes(minutes)) {
      // Refuse locally rather than round-tripping to a 400 the parent has to interpret.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Codes are worth 1 to ${TimeCodeLimits.maxMinutes} minutes.',
          ),
        ),
      );
      return;
    }
    await _mint(minutes);
  }

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
