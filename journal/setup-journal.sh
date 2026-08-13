#!/usr/bin/env bash
# setup-journal.sh — install deps and print how to run + register the journal MCP.
# Run the SERVER on the VPS. Register the CLIENT on BOTH machines.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1. install the MCP SDK (idempotent) =="
python3 -m pip install --quiet --upgrade "mcp[cli]" && echo "mcp SDK ready"

cat <<EOF

== 2. VPS: run the journal server (once) ==
  cd "$HERE"
  nohup python3 journal_mcp.py > journal.log 2>&1 &
  # it listens on http://127.0.0.1:8888/mcp  (loopback only)
  # (systemd equivalent: copy the relay unit pattern, swap ExecStart to journal_mcp.py)

== 3. LOCAL: open a tunnel to the journal port ==
  ssh -N -L 8888:127.0.0.1:8888 vps      # leave running (add -f to background)

== 4. Register the MCP client on BOTH machines ==
  # On the VPS session:
  claude mcp add --transport http journal http://127.0.0.1:8888/mcp

  # On the local session (through the tunnel — same URL):
  claude mcp add --transport http journal http://127.0.0.1:8888/mcp

  # verify inside Claude Code:
  #   /mcp        -> 'journal' should list tools: journal_log, journal_read, claim, release, claims_list

== 5. identity ==
  Each session passes its own name to the tools: local -> who="local", vps -> who="vps".
  The bridge-sync / bridge-push skills do this automatically.
EOF
