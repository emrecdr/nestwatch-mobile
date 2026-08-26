/// The SHA-256 of a server's TLS certificate, in the exact shape nestwatch speaks.
///
/// nestwatch formats fingerprints as uppercase hex with colons — `AB:CD:…` — in
/// `cert::fingerprint` (`src/cert.rs`, "SHA-256 of the DER cert, formatted `AB:CD:...`").
/// That is what `nestwatch fingerprint` prints, what `install` prints under the QR, and
/// what a parent compares by eye. Keeping one format means one parser and one test.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A parsed certificate fingerprint: the 32 raw bytes, plus the display form.
class Fingerprint {
  /// SHA-256 is 32 bytes. A fingerprint of any other length is not one.
  static const int _sha256Bytes = 32;

  final Uint8List bytes;

  const Fingerprint._(this.bytes);

  /// The fingerprint of a certificate's DER bytes.
  ///
  /// SHA-256 over the DER, which is what nestwatch's `cert::fingerprint` hashes and
  /// therefore what `nestwatch fingerprint` prints and what a QR carries. Written out at
  /// three call sites before this existed — the pin check in `_verify`, and once each in
  /// `test/` and `tool/` — and the hash choice is the part that has to agree with that PC,
  /// so it is worth having one place to be wrong.
  ///
  /// Takes DER rather than PEM on purpose. The app never sees PEM: `X509Certificate`
  /// hands it `der` directly, and a PEM decoder here would be code that ships and is only
  /// ever called by tests.
  factory Fingerprint.ofDer(List<int> der) =>
      Fingerprint.fromBytes(sha256.convert(der).bytes);

  /// Parse nestwatch's `AB:CD:…` form.
  ///
  /// Lenient about case and surrounding whitespace, because this string arrives by
  /// three routes that mangle it differently: a QR fragment, a parent retyping what
  /// `nestwatch fingerprint` printed, and a paste that picked up a newline. Strict
  /// about length, because a truncated pin is a weaker pin that still looks like one.
  factory Fingerprint.parse(String text) {
    final cleaned = text
        .trim()
        .replaceAll(':', '')
        .replaceAll(RegExp(r'\s'), '');
    if (cleaned.length != _sha256Bytes * 2) {
      throw FormatException(
        'expected a $_sha256Bytes-byte SHA-256 (${_sha256Bytes * 2} hex chars), '
        'got ${cleaned.length}',
        text,
      );
    }
    final out = Uint8List(_sha256Bytes);
    for (var i = 0; i < _sha256Bytes; i++) {
      final byte = int.tryParse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw FormatException('not hex at byte $i', text, i * 2);
      }
      out[i] = byte;
    }
    return Fingerprint._(out);
  }

  /// Wrap already-computed digest bytes (e.g. straight out of `sha256.convert`).
  factory Fingerprint.fromBytes(List<int> bytes) {
    if (bytes.length != _sha256Bytes) {
      throw FormatException(
        'expected $_sha256Bytes bytes, got ${bytes.length}',
      );
    }
    return Fingerprint._(Uint8List.fromList(bytes));
  }

  /// Render as nestwatch does, so anything we show the parent can be compared
  /// character-for-character against `nestwatch fingerprint`.
  @override
  String toString() => bytes
      .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join(':');

  /// Constant-time comparison.
  ///
  /// The timing channel here is admittedly narrow, but it is not obviously empty: an
  /// impostor on the LAN can force this comparison as often as it likes by answering
  /// the handshake, and an early-exit `==` leaks a prefix match. Constant time costs
  /// 32 XORs, so there is nothing to trade off.
  bool matches(List<int> other) {
    if (other.length != bytes.length) return false;
    var diff = 0;
    for (var i = 0; i < bytes.length; i++) {
      diff |= bytes[i] ^ other[i];
    }
    return diff == 0;
  }

  @override
  bool operator ==(Object other) =>
      other is Fingerprint && matches(other.bytes);

  @override
  int get hashCode => Object.hashAll(bytes);
}
