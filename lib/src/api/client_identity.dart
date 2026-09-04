/// How this app announces itself to that PC.
///
/// ## The card this exists to be legible in
///
/// nestwatch 0.7.0 added a *Signed-in devices* card. It lists every session the PC is
/// holding — browsers, phones, paired apps — and gives each row its own **Sign out**,
/// so a phone left in a taxi costs one click instead of a password rotation that signs
/// out the whole house. `auth::remember_device` fills each row from the `User-Agent` of
/// the request that signed in, read **once**, at `login` or at `pair`, and stored on the
/// session. It is never re-read, so this is a property of the moment a session is minted
/// rather than a header that matters on every request.
///
/// ## What it used to say
///
/// This app set no `User-Agent` at all, so `dart:io` supplied its default and the card
/// showed:
///
///     User-Agent: Dart/3.12 (dart:io)
///
/// Captured off the wire on 2026-09-05 against a local sink, with a control request
/// carrying a known string to prove the sink reported what was actually sent — not read
/// off the SDK source and assumed.
///
/// Three things are wrong with it. It names no product, so a parent cannot tell this
/// app from any other Dart program that ever paired. It says nothing about a phone, which
/// is the one thing they are looking for. And it carries the **Dart SDK** version, so the
/// row's identity changes under them when this app is rebuilt against a newer toolchain —
/// the same device, describing itself differently, in a list whose whole purpose is
/// recognising devices. nestwatch's own release notes say what that costs: *"revoking the
/// wrong device is the mistake worth guarding against."*
///
/// ## What is announced instead, and what is left out
///
/// The app, its version, and the platform. Deliberately not the device model, which is
/// the one field that would tell two Android phones apart: it needs a plugin this app
/// does not have, and `pubspec.yaml` keeps a short dependency list on purpose — every
/// entry is re-audited against the pinning rule on each `pub add`. The card already
/// separates two phones by `first_seen`, which it shows and sorts by, so the model would
/// be a new dependency and a new privacy surface to restate something the row carries.
///
/// `Platform.operatingSystemVersion` is left out for a different reason: its shape on a
/// real Android device has not been checked from here, and this file exists because an
/// unverified string was being sent. Adding a second one would be the same mistake in a
/// nicer font.
library;

import 'dart:io';

/// This app's version. Must equal the `version:` in `pubspec.yaml`.
///
/// Written out rather than read, because reading the real one needs `package_info_plus`
/// and this string is not worth a dependency. That makes it a fifth place a version can
/// disagree, so `tool/check_version.sh` compares it to `pubspec.yaml` — the same script
/// that already holds the changelog, the tag and `ContractCheck.testedAgainst` in step.
/// A number nobody checks is a number that drifts.
const String appVersion = '0.1.0';

/// The identity, built from a platform name rather than reading one.
///
/// Pure so a test can state the shape without asserting on whichever machine it runs on —
/// a test that hard-codes the host's own platform passes for the wrong reason on CI and
/// fails on a laptop.
String userAgentFor(String operatingSystem) =>
    'nestwatch-mobile/$appVersion ($operatingSystem)';

/// What this process actually sends. `android` or `ios` in the app; whatever the host is
/// under `flutter test`.
final String clientUserAgent = userAgentFor(Platform.operatingSystem);
