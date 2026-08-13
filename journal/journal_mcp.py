#!/usr/bin/env python3
"""
journal_mcp.py — a shared "what was done" ledger for the two Claude Code sessions,
exposed as MCP tools. Run ONE instance on the VPS; both sessions connect to it
(local via an SSH tunnel, VPS via localhost) so there is a single source of truth.

Tools exposed to both Claudes:
  journal_log(who, action, target?, status?, note?)  -> append an entry
  journal_read(since_id?, limit?)                     -> recent entries
  claim(who, resource, note?)                         -> acquire a lock (denied if peer holds it)
  release(who, resource)                              -> release a lock you hold
  claims_list()                                       -> current active locks

Backed by SQLite (durable, concurrency-safe). `who` is 'local' or 'vps' — each
session passes its own identity (the skills enforce this).

Requires the MCP SDK:  pip install "mcp[cli]"
Env:
  JOURNAL_DB    sqlite path (default ./journal.db next to this file)
  JOURNAL_HOST  bind host (default 127.0.0.1 — keep local, reach via SSH tunnel)
  JOURNAL_PORT  port (default 8888)
"""
import os
import sqlite3
import time

from mcp.server.fastmcp import FastMCP

DB_PATH = os.environ.get("JOURNAL_DB", os.path.join(os.path.dirname(os.path.abspath(__file__)), "journal.db"))
HOST = os.environ.get("JOURNAL_HOST", "127.0.0.1")
PORT = int(os.environ.get("JOURNAL_PORT", "8888"))

mcp = FastMCP("bridge-journal", host=HOST, port=PORT)


def _conn():
    c = sqlite3.connect(DB_PATH, timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    return c


def _init():
    with _conn() as c:
        c.execute("""CREATE TABLE IF NOT EXISTS journal (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL, who TEXT NOT NULL, action TEXT NOT NULL,
            target TEXT DEFAULT '', status TEXT DEFAULT '', note TEXT DEFAULT ''
        )""")
        c.execute("""CREATE TABLE IF NOT EXISTS claims (
            resource TEXT PRIMARY KEY, who TEXT NOT NULL, ts REAL NOT NULL, note TEXT DEFAULT ''
        )""")


_init()


def _norm(who: str) -> str:
    w = (who or "").strip().lower()
    return w if w in ("local", "vps") else (w or "unknown")


@mcp.tool()
def journal_log(who: str, action: str, target: str = "", status: str = "", note: str = "") -> dict:
    """Append an entry to the shared ledger. `who` is 'local' or 'vps'. `action`
    is a short verb like PUSH/DEPLOY/EDIT/VERIFY/DONE. Call this AFTER every
    meaningful action so the peer always sees an accurate history."""
    who = _norm(who)
    ts = time.time()
    with _conn() as c:
        cur = c.execute(
            "INSERT INTO journal (ts, who, action, target, status, note) VALUES (?,?,?,?,?,?)",
            (ts, who, action.strip(), target.strip(), status.strip(), note.strip()),
        )
        return {"ok": True, "id": cur.lastrowid, "who": who, "action": action.strip()}


@mcp.tool()
def journal_read(since_id: int = 0, limit: int = 50) -> dict:
    """Read ledger entries newer than `since_id` (0 = from start), up to `limit`.
    Call this at the START of your turn to see what the peer has done."""
    with _conn() as c:
        rows = c.execute(
            "SELECT id, ts, who, action, target, status, note FROM journal "
            "WHERE id > ? ORDER BY id ASC LIMIT ?",
            (since_id, max(1, min(limit, 500))),
        ).fetchall()
    entries = [{
        "id": r["id"], "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["ts"])),
        "who": r["who"], "action": r["action"], "target": r["target"],
        "status": r["status"], "note": r["note"],
    } for r in rows]
    return {"count": len(entries), "cursor": entries[-1]["id"] if entries else since_id, "entries": entries}


@mcp.tool()
def claim(who: str, resource: str, note: str = "") -> dict:
    """Try to acquire an exclusive lock on `resource` (e.g. a file or 'deploy').
    Returns {ok:true} if you got it (or already hold it). Returns {ok:false,
    holder:...} if the PEER holds it — do NOT touch that resource until released."""
    who = _norm(who)
    resource = resource.strip()
    ts = time.time()
    with _conn() as c:
        row = c.execute("SELECT who, ts FROM claims WHERE resource=?", (resource,)).fetchone()
        if row and row["who"] != who:
            return {"ok": False, "resource": resource, "holder": row["who"],
                    "since": time.strftime("%H:%M:%SZ", time.gmtime(row["ts"])),
                    "message": f"held by {row['who']} — wait or coordinate over SendMessage"}
        c.execute("INSERT OR REPLACE INTO claims (resource, who, ts, note) VALUES (?,?,?,?)",
                  (resource, who, ts, note.strip()))
        return {"ok": True, "resource": resource, "holder": who}


@mcp.tool()
def release(who: str, resource: str) -> dict:
    """Release a lock you hold on `resource`. Only the holder can release it."""
    who = _norm(who)
    resource = resource.strip()
    with _conn() as c:
        row = c.execute("SELECT who FROM claims WHERE resource=?", (resource,)).fetchone()
        if not row:
            return {"ok": True, "resource": resource, "note": "was not held"}
        if row["who"] != who:
            return {"ok": False, "resource": resource, "holder": row["who"],
                    "message": f"cannot release — held by {row['who']}, not you"}
        c.execute("DELETE FROM claims WHERE resource=?", (resource,))
        return {"ok": True, "resource": resource, "released_by": who}


@mcp.tool()
def claims_list() -> dict:
    """List all currently held locks and who holds them."""
    with _conn() as c:
        rows = c.execute("SELECT resource, who, ts, note FROM claims ORDER BY ts ASC").fetchall()
    return {"count": len(rows), "claims": [{
        "resource": r["resource"], "who": r["who"],
        "since": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r["ts"])), "note": r["note"],
    } for r in rows]}


if __name__ == "__main__":
    # streamable-http: reachable at http://HOST:PORT/mcp
    mcp.run(transport="streamable-http")
