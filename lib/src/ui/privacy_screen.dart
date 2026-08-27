/// What this app does with data, in the app, because Play requires it there.
///
/// The policy has to be at a public URL in the Console field **and** reachable from
/// inside the app. This is the second half.
///
/// ## Why it hangs off the pairing screen
///
/// A reviewer has no nestwatch to pair with. A policy reachable only from the signed-in
/// screens is a policy nobody assessing this app can open, and the first they would learn
/// of that is a rejection.
///
/// ## Every claim here was checked against the code
///
/// Not written from intent. `grep` for filesystem writes in `lib/` returns nothing, so
/// "nothing is written to storage except the three items below" is a fact about this
/// build rather than a promise about the design. The permissions list is read from the
/// **merged** manifest, which is the one that matters: most of those permissions arrive
/// from plugins and appear on the store listing without ever being written here.
library;

import 'package:flutter/material.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const PrivacyScreen());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _p(
            theme,
            'This app talks to one computer in your own home, over your own network. '
            'It has no account, no server of ours, and no analytics. Nothing it reads '
            'is sent anywhere except back to that computer.',
          ),
          _h(theme, 'What it keeps on this phone'),
          _bullet(
            theme,
            'The fingerprint of that computer\'s certificate — the value '
            'that lets this app tell the right computer from an impostor.',
          ),
          _bullet(
            theme,
            'A sign-in cookie, so you do not retype the password daily.',
          ),
          _bullet(
            theme,
            'The identifiers of requests you have already been told about, '
            'so the same one is not announced twice.',
          ),
          _p(
            theme,
            'All three are held in Android\'s encrypted store, under a key that cannot '
            'leave this device. They are excluded from backups and from phone-to-phone '
            'transfer. "Forget this PC" deletes all of them.',
          ),
          _h(theme, 'What it never keeps'),
          _p(
            theme,
            'Pictures of your child\'s screen are shown and then discarded. They are '
            'never written to storage on this phone, never sent anywhere, and are gone '
            'when you leave the screen. This app writes no files at all.',
          ),
          _h(theme, 'The camera'),
          _p(
            theme,
            'Used for one thing: reading the pairing code printed by the computer. '
            'Nothing the camera sees is stored, and nothing is sent.',
          ),
          _h(theme, 'Your child\'s data'),
          _p(
            theme,
            'A picture of your child\'s desktop is your child\'s personal data, and so '
            'is the list of what they used and the reasons they type when asking for '
            'more time. This app shows you that data and keeps none of it. What is '
            'recorded lives on the computer being monitored, under your control, and '
            'this app cannot make copies of it elsewhere.',
          ),
          _h(theme, 'Permissions'),
          _p(
            theme,
            'Notifications, to tell you a request is waiting. The camera, for the '
            'pairing code. Network access, to reach that one computer. A foreground '
            'service, only while you switch on "watch now", so that checking every '
            'minute is visible to you rather than hidden.',
          ),
        ],
      ),
    );
  }

  Widget _h(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 8),
    child: Text(text, style: theme.textTheme.titleMedium),
  );

  Widget _p(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: theme.textTheme.bodyMedium),
  );

  Widget _bullet(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('•  ', style: theme.textTheme.bodyMedium),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    ),
  );
}
