#!/usr/bin/env bash
# install.sh — set up claude-bridge on THIS machine (local laptop or VPS).
# Installs the skills, makes scripts executable, opts this session into inbound
# peer messages, and (optionally) runs the SSH setup wizard.
#
#   ./install.sh            # full setup, prompts for SSH
#   ./install.sh --no-ssh   # skip the SSH wizard (e.g. on the VPS side)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DO_SSH=1
[ "${1:-}" = "--no-ssh" ] && DO_SSH=0

echo "== claude-bridge install =="

# 1) skills ------------------------------------------------------------------
SKILLS="$HOME/.claude/skills"
mkdir -p "$SKILLS"
for s in bridge-push bridge-sync; do
  cp -r "$HERE/skill/$s" "$SKILLS/$s"
  chmod +x "$SKILLS/$s"/scripts/*.sh 2>/dev/null || true
  echo "   installed skill: $s"
done
chmod +x "$HERE"/*.sh "$HERE"/bridge "$HERE"/skill/*/scripts/*.sh 2>/dev/null || true

# 2) opt into inbound peer messages (crossSessionInbound: accept) -------------
SETTINGS="$HOME/.claude/settings.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$SETTINGS" <<'PY'
import json, os, sys
p = sys.argv[1]
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
except Exception:
    print("   ! settings.json is not valid JSON — skipping crossSessionInbound (set it manually)"); sys.exit(0)
if d.get("crossSessionInbound") != "accept":
    d["crossSessionInbound"] = "accept"
    json.dump(d, open(p, "w"), indent=2)
    print("   set crossSessionInbound = accept")
else:
    print("   crossSessionInbound already = accept")
PY
else
  echo "   ! python3 not found — add '\"crossSessionInbound\": \"accept\"' to $SETTINGS manually"
fi

# 3) SSH setup ---------------------------------------------------------------
if [ "$DO_SSH" -eq 1 ]; then
  echo
  read -r -p "Set up passwordless SSH to your VPS now? [Y/n]: " ans
  case "${ans:-Y}" in
    [Nn]*) echo "   skipped — run ./bridge-init.sh later";;
    *) bash "$HERE/bridge-init.sh";;
  esac
fi

echo
echo "== install complete =="
echo "Restart Claude Code (or open a new session) so the new skills + setting load."
echo "Start with:  claude --rc    (or enable 'Remote Control for all sessions' in /config)"
