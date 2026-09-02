/// A block of text in a coloured box, which this app does seven times.
///
/// Pairing uses it for "not verified yet", for a refused certificate and for a failed
/// attempt; the usage screen uses it for enforcement that may be stopped, for rules
/// switched off, and for a focus watcher that is not reporting.
///
/// The tone is the point. Every one of these says something a parent has to act on or
/// discount a number because of, and which of the two it is comes through in the colour
/// before the words are read. Seven hand-built `Container`s meant the padding, the
/// radius and — worse — the pairing of a background with its legible foreground were
/// seven places that could drift apart.
library;

import 'package:flutter/material.dart';

enum NoticeTone {
  /// Something is wrong and the numbers nearby may be lying.
  warning,

  /// Something is off or absent by choice. Worth knowing, not alarming.
  advisory,

  /// Ordinary instruction. Carries no alarm at all.
  plain,
}

class Notice extends StatelessWidget {
  final String text;
  final NoticeTone tone;

  /// Shown before the text. Only the enforcement warning uses one, and it earns it:
  /// that box is the one saying the figures below may not mean anything.
  final IconData? icon;

  final EdgeInsetsGeometry? margin;

  /// Given when the notice is the parent's to clear rather than the state's.
  ///
  /// The other seven are derived: an expired certificate, an enforcer that stopped
  /// reporting, rules switched off — each appears because something is true and goes when
  /// it stops being true, so a close button would only argue with the next rebuild.
  ///
  /// One is not like that. `curfew_note` answers an action rather than describing a
  /// state: it is the server's reply to *this* approval, there is no later payload that
  /// withdraws it, and it must not be put where it can time out. Material's own guidance
  /// is that a snackbar "shouldn't be the only way to access a core use case" and that a
  /// message needing an action belongs in something that waits — and WCAG 2.2.1 is about
  /// exactly this, since a parent using a screen reader may still be hearing the row when
  /// a four-second bar has already gone. So it waits, and dismissing is the parent's.
  final VoidCallback? onDismiss;

  const Notice(
    this.text, {
    super.key,
    this.tone = NoticeTone.plain,
    this.icon,
    this.margin,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Background and foreground are chosen together, never separately — that pairing is
    // the whole reason this is one widget.
    final (background, foreground) = switch (tone) {
      NoticeTone.warning => (scheme.errorContainer, scheme.onErrorContainer),
      NoticeTone.advisory => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      NoticeTone.plain => (scheme.surfaceContainerHighest, scheme.onSurface),
    };

    final body = Text(text, style: TextStyle(color: foreground));
    final dismiss = onDismiss;

    return Container(
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: icon == null && dismiss == null
          ? body
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: foreground),
                  const SizedBox(width: 10),
                ],
                Expanded(child: body),
                if (dismiss != null) ...[
                  const SizedBox(width: 4),
                  // Sized to the text rather than to Material's default 48dp box, which
                  // would push the words off-centre against a two-line notice. The
                  // *target* is still 48dp — `IconButton` keeps its own — so this is a
                  // layout constraint, not a smaller thing to hit.
                  IconButton(
                    onPressed: dismiss,
                    icon: const Icon(Icons.close, size: 18),
                    color: foreground,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Dismiss',
                  ),
                ],
              ],
            ),
    );
  }
}
