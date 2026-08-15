#!/usr/bin/env bash
# install.sh — set up claude-bridge on THIS machine, for any supported agent.
#
#   ./install.sh                   # Claude Code (default), prompts for SSH
#   ./install.sh --agent codex     # OpenAI Codex CLI
#   ./install.sh --agent grok      # Grok CLI / any bash-capable agent
#   ./install.sh --no-ssh          # skip the SSH wizard (e.g. on the VPS side)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT=claude
DO_SSH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:-claude}"; shift 2;;
    --no-ssh) DO_SSH=0; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1 (use --agent claude|codex|grok, --no-ssh)"; exit 1;;
  esac
done

echo "== claude-bridge install (agent: $AGENT) =="

# --- common: make scripts executable + put the relay CLI on PATH ------------
chmod +x "$HERE"/*.sh "$HERE"/bridge "$HERE"/skill/*/scripts/*.sh 2>/dev/null || true
mkdir -p "$HOME/.local/bin"
ln -sf "$HERE/bridge" "$HOME/.local/bin/bridge"
echo "   linked 'bridge' -> ~/.local/bin/bridge"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) echo "   NOTE: add ~/.local/bin to PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --- agent-specific wiring --------------------------------------------------
case "$AGENT" in
  claude)
    SKILLS="$HOME/.claude/skills"; mkdir -p "$SKILLS"
    for s in bridge-push bridge-sync; do
      cp -r "$HERE/skill/$s" "$SKILLS/$s"
      chmod +x "$SKILLS/$s"/scripts/*.sh 2>/dev/null || true
      echo "   installed skill: $s"
    done
    SETTINGS="$HOME/.claude/settings.json"
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$SETTINGS" <<'PY'
import json, os, sys
p = sys.argv[1]; os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
except Exception:
    print("   ! settings.json invalid — set crossSessionInbound:accept manually"); sys.exit(0)
if d.get("crossSessionInbound") != "accept":
    d["crossSessionInbound"] = "accept"; json.dump(d, open(p, "w"), indent=2)
    print("   set crossSessionInbound = accept")
else:
    print("   crossSessionInbound already = accept")
PY
    else
      echo "   ! python3 not found — add '\"crossSessionInbound\": \"accept\"' to $SETTINGS manually"
    fi
    ;;
  codex)
    echo "   Codex reads AGENTS.md automatically from the working directory."
    echo "   → run Codex from inside this repo, OR copy AGENTS.md into your project root:"
    echo "       cp \"$HERE/AGENTS.md\" /path/to/your/project/AGENTS.md"
    ;;
  grok|generic)
    echo "   Point your agent at AGENTS.md (its instruction/rules file) and make sure it can run bash."
    echo "   AGENTS.md lives at: $HERE/AGENTS.md"
    ;;
  *)
    echo "   ! unknown agent '$AGENT' (use: claude | codex | grok)"; exit 1;;
esac

# --- SSH setup (all agents) -------------------------------------------------
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
case "$AGENT" in
  claude)
    echo "Restart Claude Code (or open a new session) so the skills + setting load."
    echo "Start with:  claude --rc     (or enable 'Remote Control for all sessions' in /config)"
    ;;
  codex)
    echo "Start Codex in this repo — it follows AGENTS.md."
    echo "Coordinate over the relay:  bridge send/recv/wait   |   move files:  bridge put/get  (or SSH)"
    ;;
  *)
    echo "Point your agent at AGENTS.md."
    echo "Coordinate over the relay:  bridge send/recv/wait   |   move files:  bridge put/get  (or SSH)"
    ;;
esac
