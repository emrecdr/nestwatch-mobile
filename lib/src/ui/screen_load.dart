/// What a screen does with the answer to its one question.
///
/// Four screens each ask a nestwatch endpoint for one thing and have to sort the reply
/// into the same three outcomes. Two of them are obvious. The third is the reason this
/// file exists: **`sessionExpired` is not an error to put on the screen.**
///
/// A lapsed session is fixed by typing a password, not by pressing Try again, and the
/// only thing that can put up a password prompt is the controller above. So it has to
/// travel *past* the screen untouched — rendering it would give a parent a retry button
/// that cannot work and no way to reach the one that can.
///
/// Written out per screen that rule lived in four copies and was checked by nothing:
/// there are no widget tests, and `tool/mutate.sh` had no mutations under `lib/src/ui`.
/// Pulled out here it runs under plain `flutter test` with no widget, no socket and no
/// timer — the same reason `background/poll_logic.dart` is a separate file.
library;

import '../api/nestwatch_api.dart';

sealed class LoadOutcome<T> {
  const LoadOutcome();
}

/// The call answered. [data] is what it said.
final class Loaded<T> extends LoadOutcome<T> {
  final T data;
  const Loaded(this.data);
}

/// The call failed in a way this screen should say out loud.
final class Failed<T> extends LoadOutcome<T> {
  final String message;
  const Failed(this.message);
}

/// The session lapsed. Not for this screen to show — hand it up.
final class HandedBack<T> extends LoadOutcome<T> {
  final NestwatchException failure;
  const HandedBack(this.failure);
}

/// Run [fetch] and sort the result.
///
/// Only [NestwatchException] is caught. Anything else is a defect in this app rather
/// than an answer from that PC, and swallowing it into a grey message on a screen is how
/// it would go unnoticed.
Future<LoadOutcome<T>> loadOnce<T>(Future<T> Function() fetch) async {
  try {
    return Loaded(await fetch());
  } on NestwatchException catch (e) {
    if (e.failure == NestwatchFailure.sessionExpired) return HandedBack(e);
    return Failed(e.message);
  }
}
