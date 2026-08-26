#!/usr/bin/env python3
"""A TLS listener that reports exactly how much application data it received.

The point of §6's "prove the pin by failure" is not that a wrong certificate produces
an error -- a check that runs *after* the body has been streamed produces an error too,
having already handed the request to the impostor. That is the flaw in dio's published
recipe. Distinguishing the two needs a server that will say, on the record, whether any
request bytes ever crossed the wire.

Emits one JSON line per connection to stdout:
  {"event":"tcp_accept"}                       - socket opened
  {"event":"handshake_failed","detail":...}    - TLS refused; NO application data
  {"event":"handshake_ok"}                     - TLS completed
  {"event":"app_bytes","n":N,"head":"..."}     - request bytes actually received
"""
import json
import socket
import ssl
import sys
import threading

CERT, KEY, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])


def emit(**kw):
    print(json.dumps(kw), flush=True)


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", PORT))
except OSError as e:
    # A leftover sink from an earlier run still owns the port. Say so as data, on the
    # same channel as everything else, so the harness can stop instead of reading an
    # empty log as "no bytes crossed the wire" -- which looks exactly like a pass.
    emit(event="bind_failed", port=PORT, detail=str(e))
    sys.exit(1)
srv.listen(8)
emit(event="listening", port=PORT)


def handle(raw):
    emit(event="tcp_accept")
    try:
        tls = ctx.wrap_socket(raw, server_side=True)
    except (ssl.SSLError, OSError) as e:
        # The client walked away during the handshake. By construction, zero
        # application bytes were ever decrypted -- there was no session to send them in.
        emit(event="handshake_failed", detail=str(e).split("(")[0].strip())
        raw.close()
        return

    emit(event="handshake_ok")
    try:
        tls.settimeout(3)
        data = tls.recv(8192)
        if data:
            emit(event="app_bytes", n=len(data),
                 head=data.decode("utf-8", "replace")[:400])
        else:
            emit(event="app_bytes", n=0, head="")
        tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    except Exception as e:
        emit(event="post_handshake_error", detail=str(e))
    finally:
        try:
            tls.close()
        except Exception:
            pass


while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
