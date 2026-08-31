/// Why a request to that PC failed: this phone, or that PC.
///
/// ## The failure this exists for
///
/// Every transport failure used to produce one sentence — `Could not reach $authority`
/// with the operating system's own words appended. For a **LAN-only** app that is the
/// wrong answer to the most common thing that will ever happen: a parent leaving the
/// house. Walking out of range is not a fault, and it is not something to be told about
/// in terms of `errno`.
///
/// ## Why this asks the phone rather than the network
///
/// No package, and no probe. `NetworkInterface.list()` is in `dart:io`, needs no
/// permission on either platform, and answers instantly — where a connectivity plugin
/// would be a dependency to audit on a rule this repo takes seriously, and a reachability
/// ping would be another request to a PC that has already failed to answer one.
///
/// ## What it can and cannot know, exactly
///
/// `NetworkInterface` does **not** expose a netmask. So the subnet cannot be computed,
/// only guessed at, and this deliberately does not pretend otherwise:
///
///   * **no address at all** — certain. Nothing is reachable, and no PC is at fault.
///   * **the same /24** — confident enough to stop blaming the network and start
///     believing the PC really is unreachable.
///   * **anything else** — *probably* a different network, and said as "does not look
///     like", because a home router handing out a /16 would put 192.168.1.x and
///     192.168.2.x on one network while this sees two.
///
/// Guessing wide would be worse than guessing narrow here: telling a parent at home that
/// they are away sends them to the wrong place, so the wide case is the hedged one.
library;

import 'dart:io';

enum Whereabouts {
  /// This phone has no usable network at all — flight mode, or nothing joined.
  offline,

  /// A local address shares a /24 with that PC, so this looks like the home network and
  /// the failure is more likely to be the PC itself.
  looksLikeHome,

  /// Some network, but nothing that looks like that PC's. Hedged on purpose.
  looksElsewhere,

  /// The address is a name rather than a number, so none of the above can be computed.
  cannotTell,
}

/// Judge from a server host and this phone's own addresses. Pure, so it is testable
/// without a network — the part that touches `dart:io` is [localAddresses].
Whereabouts whereAmI({
  required String serverHost,
  required List<String> localAddresses,
}) {
  final server = _octets(serverHost);
  if (server == null) return Whereabouts.cannotTell;

  final usable = localAddresses.map(_octets).whereType<List<int>>().where((a) {
    // 127.x is this device talking to itself and says nothing about reachability;
    // 169.254.x is a link-local address, which means DHCP never answered.
    return a[0] != 127 && !(a[0] == 169 && a[1] == 254);
  }).toList();

  if (usable.isEmpty) return Whereabouts.offline;

  final sameSlash24 = usable.any(
    (a) => a[0] == server[0] && a[1] == server[1] && a[2] == server[2],
  );
  return sameSlash24 ? Whereabouts.looksLikeHome : Whereabouts.looksElsewhere;
}

/// The sentence a parent reads instead of an `errno`.
///
/// [authority] is `host:port` as they paired it, so it is the thing they would recognise.
String explainUnreachable(
  Whereabouts where,
  String authority,
) => switch (where) {
  Whereabouts.offline =>
    'This phone is not on any network right now, so it cannot reach $authority. '
        'Nothing is wrong with that PC — join your home Wi-Fi and this will work again.',
  Whereabouts.looksElsewhere =>
    'This phone does not look like it is on the same network as $authority. '
        'Nestwatch only works on your home Wi-Fi — it never goes through the '
        'internet, which is the point of it. Nothing here can reach that PC from '
        'somewhere else.',
  Whereabouts.looksLikeHome =>
    'This phone looks like it is on the right network, but $authority did not '
        'answer. That usually means the PC is switched off, asleep, or nestwatch is '
        'not running on it.',
  Whereabouts.cannotTell =>
    'Could not reach $authority. If you are away from home, that is expected — '
        'Nestwatch only works on your own network.',
};

/// This phone's own IPv4 addresses. Separated from [whereAmI] so the judgement is pure.
Future<List<String>> localAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return [
      for (final i in interfaces)
        for (final a in i.addresses) a.address,
    ];
  } on Object {
    // Never let diagnosing a failure become a second failure. An empty list reads as
    // offline, which is the safe direction: it blames the phone rather than the PC.
    return const [];
  }
}

List<int>? _octets(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}
