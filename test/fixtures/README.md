# Throwaway certificates for the socket-level pin test

Three self-signed certificates and their keys, used by `test/pinning_socket_test.dart`
and `test/expiry_test.dart` to stand up real TLS servers inside the test process. `PinnedHttpOverrides` can then be
exercised through an actual socket rather than by inspecting its fields.

**These keys are deliberately public and worthless.** They are committed on purpose,
because generating a certificate needs tooling Dart does not have, and a test that
shells out to `openssl` fails on machines that lack it. They authenticate nothing, are
never used outside `flutter test`, and must never be reused anywhere.

Regenerate with:

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout test/fixtures/server.key.pem -out test/fixtures/server.cert.pem \
  -days 3650 -subj "/CN=nestwatch-test-server" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

`expired.cert.pem` is the third, and it is expired on purpose — valid from 1 January
2023 to 1 January 2024, so it is dead by any clock this repo will run on:

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout test/fixtures/expired.key.pem -out test/fixtures/expired.cert.pem \
  -not_before 20230101000000Z -not_after 20240101000000Z \
  -subj "/CN=nestwatch-test-expired" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

It settles a question that had only been argued: because `badCertificateCallback` is the
sole authority, does a pinned client accept a certificate that has expired? It does —
`test/expiry_test.dart` completes a request against a server presenting this one, and the
browser would refuse the same certificate outright. That asymmetry is why the app warns.

The tests read the fingerprints off the certificates at runtime, so regenerating needs
no other edit.
