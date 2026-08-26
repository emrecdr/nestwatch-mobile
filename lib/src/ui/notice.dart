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

  const Notice(
    this.text, {
    super.key,
    this.tone = NoticeTone.plain,
    this.icon,
    this.margin,
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

    return Container(
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: icon == null
          ? body
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: foreground),
                const SizedBox(width: 10),
                Expanded(child: body),
              ],
            ),
    );
  }
}
