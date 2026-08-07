#!/usr/bin/env python3
import argparse
import base64
import http.server
import pathlib
import ssl
import time


class Handler(http.server.SimpleHTTPRequestHandler):
    cover_path = None
    redirect_url = None
    protected_username = "catalog-user"
    protected_password = "catalog-password"

    def protected_response(self):
        expected = "Basic " + base64.b64encode(
            f"{self.protected_username}:{self.protected_password}".encode()
        ).decode()
        supplied = self.headers.get("Authorization")
        if supplied == expected:
            return True
        self.send_response(401 if supplied is None else 403)
        self.send_header("WWW-Authenticate", 'Basic realm="BokOPDS test catalog"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def do_GET(self):
        if self.path == "/protected.xml":
            if not self.protected_response():
                return
            payload = (pathlib.Path(self.directory) / "root.xml").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/atom+xml")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/protected-book.epub":
            if not self.protected_response():
                return
            payload = (pathlib.Path(self.directory) / "books" / "1.epub").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/epub+zip")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/auth-check":
            payload = self.headers.get("Authorization", "none").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/redirect" and self.redirect_url:
            self.send_response(302)
            self.send_header("Location", self.redirect_url)
            self.end_headers()
            return
        if self.path == "/covers/1.jpg" and self.cover_path:
            payload = pathlib.Path(self.cover_path).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/covers/oversized.png":
            payload = (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" +
                       (20000).to_bytes(4, "big") + (20000).to_bytes(4, "big") +
                       b"\x08\x02\x00\x00\x00")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/covers/not-an-image.jpg":
            payload = b"not an image"
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/slow":
            time.sleep(10)
            self.send_response(200)
            self.send_header("Content-Type", "application/atom+xml")
            self.end_headers()
            try:
                self.wfile.write(b"<feed></feed>")
            except BrokenPipeError:
                pass
            return
        super().do_GET()

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=pathlib.Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cover", type=pathlib.Path, required=True)
    parser.add_argument("--certfile", type=pathlib.Path)
    parser.add_argument("--keyfile", type=pathlib.Path)
    parser.add_argument("--redirect-url")
    args = parser.parse_args()
    Handler.cover_path = args.cover
    Handler.redirect_url = args.redirect_url
    handler = lambda *handler_args, **kwargs: Handler(
        *handler_args, directory=str(args.directory), **kwargs
    )
    with http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler) as server:
        if args.certfile:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(args.certfile, args.keyfile)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
