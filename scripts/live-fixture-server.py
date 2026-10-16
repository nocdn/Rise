"""Serves a live check's pages at the addresses they pretend to be at, such as
https://www.youtube.com/watch?v=rise-fixture, which Chromium is told to send here.

    python3 scripts/live-fixture-server.py <folder> <port> [<certificate> <key>]

A check registers a page by writing it to <folder>/pages/<hex of its address's UTF-8>, the address
without its fragment; anything else is a file in <folder>. With a certificate and key it's HTTPS."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import sys

folder, port = Path(sys.argv[1]), int(sys.argv[2])
secure = len(sys.argv) > 4


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        address = f"{'https' if secure else 'http'}://{host}{self.path}"
        page = folder / "pages" / address.encode().hex()
        if not page.exists():
            return super().do_GET()
        body = page.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write(f"{self.headers.get('Host')} {format % args}\n")


server = ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, directory=str(folder)))
if secure:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[3], sys.argv[4])
    server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
