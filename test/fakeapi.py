#!/usr/bin/env python3
"""Stand-in for the two public PingTab maps-setup endpoints.

Usage: fakeapi.py <mode> <port> [portfile]

With port 0 the OS picks a free port and the bound port is written to
<portfile>, which is how run.sh learns where to point --api without a race.

It answers `GET /api/maps-setup/<code>` and `POST /api/maps-setup/<code>/keys`.
Every POST is logged to stderr as `POST <path> body=<json>`, which is how
run.sh asserts what was sent and, for dry runs, that nothing was.

A POST is checked against the contract before any mode shapes the answer: the
path must be /api/maps-setup/<8-char code>/keys, the body must be JSON with at
least one of server_key / browser_key as a non-empty string, and project_id,
when present, a string. Anything else is logged as `BAD POST <why>` and gets a
422, so a script that stops sending what the real backend requires fails the
happy-path case instead of sailing through a lenient fake.

Modes shape the responses:

  ok              GET returns both IP and referrer lists; POST saves both keys
  noips           GET returns an empty allowed_ips list, so only the browser
                  key is provisioned
  notfound        GET returns the contract's 404 with its `detail`
  serverreject    POST saves the browser key and reports the server key refused
                  by Google, with a reason
  postfail        POST returns 500
  post404         POST returns the contract's 404
  postgarbage     POST returns 200 whose body is not JSON at all
  incomplete      POST returns 200 with neither per-key section
  halfincomplete  POST returns 200 with only the browser section
  emptysection    POST returns 200 where `server` is an empty object
  savedstring     POST returns 200 where `server.saved` is the string "yes"

The last five exist to prove the script treats an unreadable outcome exactly
like a failed POST: it must fall back to printing the keys, never claim success.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8931
PORTFILE = sys.argv[3] if len(sys.argv) > 3 else None

KEYS_PATH = re.compile(r"^/api/maps-setup/[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}/keys$")

NOT_FOUND = {
    "detail": "This code is not valid or has expired. Go back to the "
              "PingTab settings screen and click Set up again."
}

ORG = "Pepper Kerala Cabs"
REFERRERS = ["https://app.pingtab.com/*", "https://pepper.pingtab.com/*"]

SAVED = {"sent": True, "saved": True, "reason": None}
NOT_SENT = {"sent": False, "saved": False, "reason": None}
REFUSED = {
    "sent": True,
    "saved": False,
    "reason": "Routes API has not been used in project pepper-cabs-01 "
              "or it is disabled",
}

POST_BODIES = {
    "serverreject": {"organization_name": ORG, "server": REFUSED, "browser": SAVED},
    "noips": {"organization_name": ORG, "server": NOT_SENT, "browser": SAVED},
    "incomplete": {"organization_name": ORG},
    "halfincomplete": {"organization_name": ORG, "browser": SAVED},
    "emptysection": {"organization_name": ORG, "server": {}, "browser": SAVED},
    "savedstring": {
        "organization_name": ORG,
        "server": {"sent": True, "saved": "yes", "reason": None},
        "browser": SAVED,
    },
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, payload, raw=False):
        body = payload if raw else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if MODE == "notfound":
            return self._send(404, NOT_FOUND)
        config = {
            "organization_name": ORG,
            "allowed_ips": [] if MODE == "noips" else ["203.0.113.10", "203.0.113.11"],
            "allowed_referrers": REFERRERS,
            "expires_at": "2026-09-04T11:22:33Z",
        }
        return self._send(200, config)

    def _bad_post(self, why, body):
        sys.stderr.write("BAD POST %s: %s body=%s\n" % (self.path, why, body.decode(errors="replace")))
        sys.stderr.flush()
        return self._send(422, {"detail": why})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)

        # The contract, enforced. See the module docstring.
        if not KEYS_PATH.match(self.path):
            return self._bad_post("path is not /api/maps-setup/<code>/keys", body)
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return self._bad_post("Content-Type is not application/json", body)
        try:
            data = json.loads(body.decode())
        except (UnicodeDecodeError, ValueError):
            return self._bad_post("body is not JSON", body)
        if not isinstance(data, dict):
            return self._bad_post("body is not an object", body)
        unknown = set(data) - {"server_key", "browser_key", "project_id"}
        if unknown:
            return self._bad_post("unknown fields %s" % sorted(unknown), body)
        keys = [k for k in ("server_key", "browser_key") if k in data]
        if not keys:
            return self._bad_post("neither server_key nor browser_key sent", body)
        for k in keys:
            v = data[k]
            if not isinstance(v, str) or not (20 <= len(v) <= 200) or any(c.isspace() for c in v):
                return self._bad_post("%s is not a 20..200 char string without whitespace" % k, body)
        if "project_id" in data and not (isinstance(data["project_id"], str) and 0 < len(data["project_id"]) <= 100):
            return self._bad_post("project_id is not a 1..100 char string", body)

        sys.stderr.write("POST %s body=%s\n" % (self.path, body.decode()))
        sys.stderr.flush()

        if MODE == "postfail":
            return self._send(500, {"detail": "boom"})
        if MODE == "post404":
            return self._send(404, NOT_FOUND)
        if MODE == "postgarbage":
            return self._send(200, b"<html>nope</html>", raw=True)
        if MODE in POST_BODIES:
            return self._send(200, POST_BODIES[MODE])
        return self._send(200, {
            "organization_name": ORG,
            "server": SAVED,
            "browser": SAVED,
        })


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    if PORTFILE:
        with open(PORTFILE, "w") as fh:
            fh.write("%d\n" % server.server_address[1])
    server.serve_forever()
