#!/usr/bin/env python3
"""
claude-bridge relay — a tiny durable message bus for two (or more) Claude Code
CLIs to talk to each other.

Zero dependencies (Python 3.8+ stdlib only). Run this on the VPS.

Messages are persisted in SQLite so long-running jobs survive relay restarts and
a peer that was offline can catch up. Delivery is via HTTP long-poll, so a
`wait` returns within milliseconds of a new message without busy-looping.

Auth: every request must carry  Authorization: Bearer <BRIDGE_TOKEN>.

Env:
  BRIDGE_TOKEN   shared secret (required; refuses to start without it)
  BRIDGE_HOST    bind address (default 127.0.0.1 — keep it local, tunnel over SSH)
  BRIDGE_PORT    port (default 8787)
  BRIDGE_DB      sqlite path (default ./bridge.db)
"""

import json
import os
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = os.environ.get("BRIDGE_TOKEN")
HOST = os.environ.get("BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "8787"))
DB_PATH = os.environ.get("BRIDGE_DB", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridge.db"))

# --- storage -----------------------------------------------------------------

_db_lock = threading.Lock()
_new_msg = threading.Condition()  # notified whenever a message is inserted

_db = sqlite3.connect(DB_PATH, check_same_thread=False)
_db.execute("""
CREATE TABLE IF NOT EXISTS messages (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    ts      REAL    NOT NULL,
    sender  TEXT    NOT NULL,
    target  TEXT    NOT NULL,          -- peer name, or '*' for broadcast
    channel TEXT    NOT NULL DEFAULT 'main',
    kind    TEXT    NOT NULL DEFAULT 'msg',  -- msg | task | result | done | note
    body    TEXT    NOT NULL
)
""")
_db.commit()


def insert(sender, target, kind, body, channel, ts):
    with _db_lock:
        cur = _db.execute(
            "INSERT INTO messages (ts, sender, target, channel, kind, body) VALUES (?,?,?,?,?,?)",
            (ts, sender, target, channel, kind, body),
        )
        _db.commit()
        mid = cur.lastrowid
    with _new_msg:
        _new_msg.notify_all()
    return mid


def fetch(peer, since_id, channel=None):
    """Messages newer than since_id addressed to `peer` (or broadcast)."""
    q = "SELECT id, ts, sender, target, channel, kind, body FROM messages WHERE id > ? AND (target = ? OR target = '*')"
    args = [since_id, peer]
    if channel:
        q += " AND channel = ?"
        args.append(channel)
    q += " ORDER BY id ASC"
    with _db_lock:
        rows = _db.execute(q, args).fetchall()
    cols = ("id", "ts", "sender", "target", "channel", "kind", "body")
    return [dict(zip(cols, r)) for r in rows]


def max_id():
    with _db_lock:
        row = _db.execute("SELECT COALESCE(MAX(id), 0) FROM messages").fetchone()
    return row[0]


# --- http --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _authed(self):
        got = self.headers.get("Authorization", "")
        if got != f"Bearer {TOKEN}":
            self._json(401, {"error": "unauthorized"})
            return False
        return True

    def _json(self, code, obj):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            return self._json(200, {"ok": True, "max_id": max_id()})
        if not self._authed():
            return
        qs = parse_qs(u.query)
        if u.path == "/poll":
            peer = qs.get("peer", [""])[0]
            if not peer:
                return self._json(400, {"error": "peer required"})
            since = int(qs.get("since", ["0"])[0])
            channel = qs.get("channel", [None])[0]
            wait = min(float(qs.get("wait", ["25"])[0]), 55.0)
            deadline = time.monotonic() + wait
            while True:
                msgs = fetch(peer, since, channel)
                if msgs or wait == 0:
                    return self._json(200, {"messages": msgs, "cursor": msgs[-1]["id"] if msgs else since})
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return self._json(200, {"messages": [], "cursor": since})
                with _new_msg:
                    _new_msg.wait(timeout=min(remaining, 5.0))
        if u.path == "/history":
            peer = qs.get("peer", ["*"])[0]
            since = int(qs.get("since", ["0"])[0])
            return self._json(200, {"messages": fetch(peer, since)})
        if u.path == "/blob":
            p = _safe_blob_path(qs.get("name", [""])[0])
            if not p or not os.path.isfile(p):
                return self._json(404, {"error": "blob not found"})
            data = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authed():
            return
        u = urlparse(self.path)
        if u.path == "/send":
            try:
                d = self._body()
            except Exception as e:
                return self._json(400, {"error": f"bad json: {e}"})
            sender = d.get("from")
            target = d.get("to")
            body = d.get("body", "")
            if not sender or not target:
                return self._json(400, {"error": "from and to required"})
            mid = insert(sender, target, d.get("kind", "msg"), body,
                         d.get("channel", "main"), time.time())
            return self._json(200, {"id": mid})
        if u.path == "/blob":
            qs = parse_qs(u.query)
            p = _safe_blob_path(qs.get("name", [""])[0])
            if not p:
                return self._json(400, {"error": "bad blob name"})
            n = int(self.headers.get("Content-Length", "0"))
            data = self.rfile.read(n) if n else b""
            with open(p, "wb") as f:
                f.write(data)
            return self._json(200, {"ok": True, "name": os.path.basename(p), "bytes": len(data)})
        return self._json(404, {"error": "not found"})


BLOB_DIR = os.environ.get("BRIDGE_BLOBS") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "blobs")


def _safe_blob_path(name):
    base = os.path.basename((name or "").strip())
    if not base or base in (".", "..") or "/" in base or "\\" in base:
        return None
    os.makedirs(BLOB_DIR, exist_ok=True)
    return os.path.join(BLOB_DIR, base)


def main():
    if not TOKEN:
        raise SystemExit("BRIDGE_TOKEN is required. Set it in the environment before starting.")
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"claude-bridge relay listening on http://{HOST}:{PORT}  db={DB_PATH}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
