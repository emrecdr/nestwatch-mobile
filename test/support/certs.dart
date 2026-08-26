/// The throwaway certificates the tests serve, and how to fingerprint one.
///
/// This existed as `fingerprintOf` inside `pinning_socket_test.dart`, which
/// `api_wire_test.dart` and `poll_logic_test.dart` then imported from — a test file
/// importing another test file, which happens when a helper has nowhere else to live.
/// Two of those files did not otherwise care about socket-level pinning at all.
///
/// The hashing itself moved further, to `Fingerprint.ofDer`: the app does the same thing
/// to every certificate it is offered, and the choice of SHA-256 over DER is the part
/// that has to agree with that PC. What stays here is the PEM decoding, which the app
/// never does — `X509Certificate` hands it `der` directly, so a PEM decoder in shipped
/// code would only ever be called by tests.
library;

import 'dart:convert';
import 'dart:io';

import 'package:nestwatch_mobile/src/pinning/fingerprint.dart';

/// Where the fixture certificates live. See `test/fixtures/README.md` for why they are
/// committed and why they are safe to commit.
const String fixtureDir = 'test/fixtures';

/// The fingerprint of a PEM certificate on disk.
///
/// Read at runtime rather than hard-coded, so regenerating the fixtures needs no edit
/// here — the claim `test/fixtures/README.md` makes about them.
Fingerprint fingerprintOf(String pemPath) =>
    Fingerprint.ofDer(base64.decode(_derOf(File(pemPath).readAsStringSync())));

/// The base64 body of a PEM block, without the `-----BEGIN/END-----` lines.
String _derOf(String pem) => pem
    .split('\n')
    .where((l) => !l.startsWith('-----'))
    .join()
    .replaceAll(RegExp(r'\s'), '');
