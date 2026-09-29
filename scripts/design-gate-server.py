"""Loopback-only server for the /feature design gate. Started by `design-gate.sh serve`.

    python3 design-gate-server.py <run-dir>

Serves <run-dir> on 127.0.0.1 at a random port, writes the base URL to <run-dir>/gate.url, and
accepts the page's notes at POST /__notes, written atomically to <run-dir>/notes.json. The
orchestrator waits on that file (`design-gate.sh wait`) for the user's decision.

Guards, because a local server is reachable by any page the user has open:
- bound to 127.0.0.1 only;
- a POST must be Content-Type: application/json, so a cross-origin page cannot send one without
  a CORS preflight, which this server never answers;
- the Host header must name this exact loopback port, so DNS rebinding cannot reach it;
- the body is capped at 1 MiB and must be a JSON object with a `notes` list.
"""
import json
import os
import sys
import tempfile
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

RUN_DIR = os.path.abspath(sys.argv[1])
NOTES = os.path.join(RUN_DIR, "notes.json")
MAX_BODY = 1 << 20


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):  # keep the background task output quiet
        pass

    def _reply(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def do_POST(self):
        port = self.server.server_address[1]
        if self.path != "/__notes":
            return self._reply(404, "not found")
        if self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            return self._reply(403, "bad host")
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return self._reply(415, "json only")
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._reply(413, "bad length")
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            return self._reply(400, "bad json")
        if not isinstance(body, dict) or not isinstance(body.get("notes"), list):
            return self._reply(400, "expected {notes: [...]}")
        # The run is whatever directory this server serves, never what the page claims.
        body["run"] = os.path.basename(RUN_DIR)
        fd, tmp = tempfile.mkstemp(dir=RUN_DIR, prefix=".notes-", suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(body, f, indent=2)
        os.replace(tmp, NOTES)
        self._reply(200, "ok")


server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=RUN_DIR))
url = f"http://127.0.0.1:{server.server_address[1]}/"
with open(os.path.join(RUN_DIR, "gate.url"), "w") as f:
    f.write(url + "\n")
print(url, flush=True)
server.serve_forever()
