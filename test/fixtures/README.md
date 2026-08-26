# Throwaway certificates for the socket-level pin test

Two self-signed certificates and their keys, used by `test/pinning_socket_test.dart` to
stand up a real TLS server inside the test process. `PinnedHttpOverrides` can then be
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

The test reads the fingerprints off the certificates at runtime, so regenerating needs
no other edit.
