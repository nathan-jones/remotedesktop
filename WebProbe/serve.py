#!/usr/bin/env python3
"""Serves the browser probe page and saves the results each browser sends back.

Usage: serve.py [port] [address]

Listens on this Mac only (127.0.0.1) unless an address is given. Over plain
http from another device the page loads, but WebCodecs is hidden: it only
exists on HTTPS pages, so put an HTTPS front end such as `tailscale funnel`
in front for the video decoding tests.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPORTS = ROOT / "reports"
FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/samples.js": ("samples.js", "text/javascript; charset=utf-8"),
}
MAX_REPORT = 1_000_000


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        entry = FILES.get(self.path.split("?")[0])
        if entry is None:
            self.send_error(404)
            return
        body = (ROOT / entry[0]).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", entry[1])
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if self.path.split("?")[0] != "/report" or not 0 < length <= MAX_REPORT:
            self.send_error(400)
            return
        try:
            report = json.loads(self.rfile.read(length))
            if not isinstance(report, dict):
                raise ValueError("not an object")
        except ValueError:
            self.send_error(400)
            return
        REPORTS.mkdir(exist_ok=True)
        # One file per page load: later sends from the same load replace earlier ones.
        stamp = "".join(c for c in str(report.get("at", "")) if c.isdigit())[:14] or str(int(time.time()))
        path = REPORTS / f"report-{stamp}.json"
        path.write_text(json.dumps(report, indent=2))
        agent = str(report.get("env", {}).get("userAgent", "unknown browser"))[:90]
        print(f"[{time.strftime('%H:%M:%S')}] {report.get('verdict', 'no verdict yet')}")
        print(f"           {agent}")
        print(f"           saved {path}", flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"Probe page on http://{host}:{port}/  (Ctrl-C to stop)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
