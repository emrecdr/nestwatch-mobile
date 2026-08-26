# nestwatch-mobile

Android client for [nestwatch](https://github.com/emrecdr/nestwatch) — a LAN-only parental
dashboard served by a Rust binary on the monitored PC. Nothing leaves the house, so this app
talks to that PC directly over HTTPS with a **pinned certificate** and no cloud in between.

The implementation plan is [`docs/PLAN.md`](docs/PLAN.md). It is validated, and it is the
source of truth for the server contract — read it before changing anything here.

## Status

Walking skeleton (PLAN §9), **step 2 of 5**: the pinned `HttpClient`, proven by failure.
Steps 3–5 (QR pairing, password login, the three screens) are not built.

## The one dependency rule

No package may bypass `dart:io`'s `HttpClient`. `HttpOverrides.global` is what pins every
request in the process; `cupertino_http`, `cronet_http`, or anything opening a raw
`SecureSocket` hands its traffic to a stack this override never sees. **Audit on every
`pub add`, not once at the start:**

```bash
grep -rln 'cupertino_http\|cronet_http\|SecureSocket\|HttpOverrides.runZoned' \
  ~/.pub-cache/hosted/pub.dev/<each-resolved-package>/lib
```

`http.runWithClient` is a false positive — it swaps `package:http`'s `Client`, and `IOClient`
still bottoms out at the `HttpClient()` factory that consults the override.

## Proving the pin

Not "wrong cert ⇒ error" — that passes against an implementation that checks the certificate
*after* streaming the request body, which is the flaw in dio's published recipe. The proof has
to show **nothing crossed the wire**.

Stand up two nestwatch instances with different certificates, plus a TLS listener that counts
application bytes:

```bash
# real server
cd ../nestwatch
NESTWATCH_DATA_DIR=/tmp/nestwatch-dev NESTWATCH_PASSWORD=dev-password-4-testing \
  cargo run -- install --port 8443
NESTWATCH_DATA_DIR=/tmp/nestwatch-dev cargo run -- run &

# impostor: same software, same SANs, different certificate
NESTWATCH_DATA_DIR=/tmp/nestwatch-impostor NESTWATCH_PASSWORD=impostor-password-4-testing \
  cargo run -- install --port 8444
NESTWATCH_DATA_DIR=/tmp/nestwatch-impostor cargo run -- run &

# byte-counting sink, presenting the impostor's certificate
cd ../nestwatch-mobile
python3 tool/wire_sink.py /tmp/nestwatch-impostor/cert.pem \
  /tmp/nestwatch-impostor/key.pem 9443 > /tmp/nestwatch-sink.log &

dart run tool/prove_pin.dart \
  --pin "$(cd ../nestwatch && NESTWATCH_DATA_DIR=/tmp/nestwatch-dev cargo run -q -- fingerprint | tail -1)" \
  --real 8443 --impostor 8444 --sink 9443
```

Four checks, and check 4 is the one that keeps it honest: it re-runs the same rig with the
sink's own certificate pinned and requires the body to arrive. Without it, a broken rig that
reports "no bytes" for any reason would pass check 3 against any implementation.

## Unit tests

```bash
flutter test        # fingerprint parsing and comparison — no server needed
```

## Layout

```
lib/src/pinning/fingerprint.dart            AB:CD: parsing, constant-time compare
lib/src/pinning/pinned_http_overrides.dart  the pin, and why withTrustedRoots: false
lib/src/pinning/pin_mismatch_message.dart   explaining a refusal to a parent
lib/main.dart                               step-2 probe screen
tool/prove_pin.dart                         the proof-by-failure harness
tool/wire_sink.py                           TLS listener that counts application bytes
```
