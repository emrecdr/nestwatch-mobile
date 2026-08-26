/// Displaying a fingerprint for a human to compare against a console.
///
/// ## Why this is laid out the way it is
///
/// Manual fingerprint comparison is a well-studied and unreliable act. The USENIX 2016
/// study of textual key-fingerprint representations found attack success rates against
/// inattentive comparers ranging from 6% to 72% depending purely on how the value was
/// presented, and it found hexadecimal specifically *more* vulnerable to partial
/// preimage attacks than alphanumeric or numeric encodings — an attacker grinds a key
/// whose fingerprint matches in the places people actually look.
///
/// Two consequences are baked in here:
///
/// **Never truncate, and never highlight a prefix.** Showing the first eight characters
/// invites comparing only those, and matching eight hex characters is a ~2^32 search —
/// hours on a laptop. The whole 95-character value is shown, every time.
///
/// **No compare-and-select.** The same literature finds that offering the real
/// fingerprint among decoys performs *worse* than plain comparison, which rules out the
/// obvious "which of these three matches your screen?" design.
///
/// The encoding itself is not ours to choose: nestwatch prints uppercase hex with
/// colons and a parent compares against that, so a friendlier encoding here would mean
/// comparing two things that do not look alike — strictly worse than a hard format
/// shown honestly. What is left is legibility: fixed-width glyphs, and grouping so the
/// eye can hold a position.
library;

import 'package:flutter/material.dart';

import '../pinning/fingerprint.dart';

/// Renders a fingerprint as grouped, fixed-width rows.
class FingerprintView extends StatelessWidget {
  final Fingerprint fingerprint;

  /// Byte-pairs per row. Eight gives four rows for SHA-256 and stays inside a phone's
  /// width at a readable size.
  static const int _perRow = 8;

  const FingerprintView(this.fingerprint, {super.key});

  @override
  Widget build(BuildContext context) {
    final groups = fingerprint.toString().split(':');
    final rows = <List<String>>[];
    for (var i = 0; i < groups.length; i += _perRow) {
      rows.add(groups.sublist(i, (i + _perRow).clamp(0, groups.length)));
    }

    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(
                row.join(' '),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  height: 1.35,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
