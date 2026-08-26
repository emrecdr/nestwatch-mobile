#!/usr/bin/env python3
"""A TLS server that answers 403 to everything, standing in for `require_lan_peer`.

PLAN.md §6 asks for the off-LAN case to be tested: "with a VPN active on the phone,
`require_lan_peer` will 403, and the message should say so rather than 'server
unreachable'". Producing a genuine off-LAN peer needs a routable address the server can
see as non-private, which a loopback dev box cannot offer -- so this reproduces what the
client actually receives.

That is the honest scope: nestwatch's own tests cover *when* it answers 403; this covers
what this app does with one, which is the half written here.
"""
import http.server
import ssl
import sys

CERT, KEY, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])


class Gate(http.server.BaseHTTPRequestHandler):
    def _deny(self):
        # Matches what `require_lan_peer` returns: a bare 403 with no body, refused by
        # middleware before any auth work happens.
        self.send_response(403)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = do_POST = _deny

    def log_message(self, *_):
        pass


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
httpd = http.server.HTTPServer(("127.0.0.1", PORT), Gate)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print(f'{{"event":"listening","port":{PORT}}}', flush=True)
httpd.serve_forever()
