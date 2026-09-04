/// The sign-in notice cannot displace a pending time request, or be displaced by one.
///
/// Every request notification is posted under `request.id.hashCode`, and the sign-in
/// notice needs an id of its own. A fixed *positive* constant would be a bet that no
/// request id ever hashes to it — and losing that bet is silent and bad in both
/// directions: a lapsed session quietly replacing a child's pending request, or a request
/// arriving and wiping the notice that says the app cannot answer it.
///
/// [signInNoticeId] is negative instead, which turns the bet into a property: if
/// `String.hashCode` is never negative, the two ranges cannot overlap at all. That is an
/// assumption about someone else's hash function, so it is asserted here rather than
/// trusted — the same reason `client_identity_test.dart` exists rather than a comment
/// asserting what `dart:io` sends.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nestwatch_mobile/src/background/notifications.dart';

void main() {
  test('the sign-in notice sits outside the range request ids can reach', () {
    expect(signInNoticeId, isNegative);
  });

  test('String.hashCode never reaches that range', () {
    final random = Random(20260905);
    var lowest = 0x7fffffffffffffff;

    for (var i = 0; i < 50000; i++) {
      final id = String.fromCharCodes(
        List.generate(1 + random.nextInt(40), (_) => 32 + random.nextInt(95)),
      );
      lowest = min(lowest, id.hashCode);
    }

    // And the shapes a real request id actually takes, which random printable strings
    // may never produce: nestwatch mints short opaque ids, and the empty string is what
    // a malformed payload decodes to.
    for (final id in const [
      '',
      'a',
      '0',
      'req-1',
      '550e8400-e29b-41d4-a716-446655440000',
    ]) {
      lowest = min(lowest, id.hashCode);
    }

    expect(
      lowest,
      greaterThan(signInNoticeId),
      reason:
          'a request id hashing to $signInNoticeId would let a pending request and the '
          '"sign in again" notice silently replace one another',
    );
    expect(lowest, isNonNegative);
  });
}
