"""A site that asks for a client certificate, and a certificate for it in the login keychain, for
the certificates live check (scripts/test-chromium-live.py certificates).

    python3 scripts/client-certificate-fixture.py setup <folder> <team>    # test CA, certificates, keychain identity
    python3 scripts/client-certificate-fixture.py import <p12> <password> <team>  # another identity, such as badssl.com's
    python3 scripts/client-certificate-fixture.py serve <folder> <port>
    python3 scripts/client-certificate-fixture.py teardown <folder>        # takes the test keychain away

The identity, "Rise Test Client", is issued by a test CA made for the run. It goes into a keychain of
the check's own, never the login keychain: one with a password this script knows, so it can stay
unlocked and grant the key to apps signed by <team> (the probe, signed as Rise is) itself. macOS
asks for a password only to make that grant, so signing with the key never asks. The keychain sits
in the user's search list while the check runs, where Chromium and the chooser find it; teardown
takes it out of the list and deletes it.
The server asks for a certificate from that CA and answers with the name on the one it was sent."""
import http.server
import ssl
import subprocess
import sys
from pathlib import Path

CLIENT_NAME = "Rise Test Client"
KEYCHAIN = str(Path.home() / "Library/Keychains/rise-test-certificates.keychain-db")
PASSWORD = "rise-test"


def run(*arguments, **options):
    return subprocess.run(arguments, check=True, capture_output=True, **options)


def search_list():
    listed = subprocess.run(["security", "list-keychains", "-d", "user"], check=True, capture_output=True, text=True).stdout
    return [line.strip().strip('"') for line in listed.splitlines() if line.strip()]


def open_keychain():
    """The check's keychain, made if need be, unlocked, and in the user's search list."""
    if not Path(KEYCHAIN).exists():
        run("security", "create-keychain", "-p", PASSWORD, KEYCHAIN)
    run("security", "unlock-keychain", "-p", PASSWORD, KEYCHAIN)
    run("security", "set-keychain-settings", KEYCHAIN)  # No locking after a while, or on sleep.
    listed = search_list()
    if KEYCHAIN not in listed:
        run("security", "list-keychains", "-d", "user", "-s", *listed, KEYCHAIN)


def import_identity(p12: Path, password: str, team: str):
    open_keychain()
    run("security", "import", str(p12), "-k", KEYCHAIN, "-P", password, "-A")
    # Grants the key to apps signed by the team, and to Apple's tools, with the keychain's own password.
    run("security", "set-key-partition-list", "-S", f"apple-tool:,apple:,teamid:{team}", "-s", "-k", PASSWORD, KEYCHAIN)


def setup(folder: Path, team: str):
    folder.mkdir(parents=True, exist_ok=True)
    ca, server, client = folder / "ca", folder / "server", folder / "client"
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=Rise Test CA",
        "-keyout", f"{ca}.key", "-out", f"{ca}.pem")
    for name, subject in ((server, "/CN=localhost"), (client, f"/CN={CLIENT_NAME}")):
        run("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", subject, "-keyout", f"{name}.key", "-out", f"{name}.csr")
        usage = "extendedKeyUsage=clientAuth" if name == client else "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1"
        Path(f"{name}.ext").write_text(usage + "\n")
        run("openssl", "x509", "-req", "-in", f"{name}.csr", "-CA", f"{ca}.pem", "-CAkey", f"{ca}.key", "-CAcreateserial",
            "-days", "2", "-extfile", f"{name}.ext", "-out", f"{name}.pem")
    run("openssl", "pkcs12", "-export", "-inkey", f"{client}.key", "-in", f"{client}.pem", "-name", CLIENT_NAME,
        "-passout", "pass:rise", "-out", f"{client}.p12")
    teardown(folder)  # An earlier run's, if it stopped before taking it away.
    import_identity(Path(f"{client}.p12"), "rise", team)


def teardown(folder: Path):
    listed = search_list()
    if KEYCHAIN in listed:
        run("security", "list-keychains", "-d", "user", "-s", *[path for path in listed if path != KEYCHAIN])
    if Path(KEYCHAIN).exists():
        run("security", "delete-keychain", KEYCHAIN)


def serve(folder: Path, port: int):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(folder / "server.pem", folder / "server.key")
    context.load_verify_locations(folder / "ca.pem")
    context.verify_mode = ssl.CERT_REQUIRED

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            certificate = self.connection.getpeercert() or {}
            name = next((value for field in certificate.get("subject", ()) for key, value in field if key == "commonName"), "")
            body = f"<!doctype html><title>certificate</title><h1 id=name>Hello, {name}</h1>".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *arguments):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    server.serve_forever()


if __name__ == "__main__":
    command, folder = sys.argv[1], Path(sys.argv[2])
    {"setup": lambda: setup(folder, sys.argv[3]), "teardown": lambda: teardown(folder),
     "import": lambda: import_identity(folder, sys.argv[3], sys.argv[4]),
     "serve": lambda: serve(folder, int(sys.argv[3]))}[command]()
