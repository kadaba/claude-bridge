#!/usr/bin/env bash
# claude-bridge setup helper. Run on EACH machine.
#   ./setup.sh vps    http://127.0.0.1:8787   <TOKEN>
#   ./setup.sh local  http://127.0.0.1:8787   <TOKEN>
# The URL is what THIS machine uses to reach the relay. On the VPS itself it's
# the local bind address; on your laptop it's the near side of the SSH tunnel.
set -euo pipefail

PEER="${1:?usage: setup.sh <peer-name> <relay-url> <token>}"
URL="${2:?relay url required}"
TOKEN="${3:?token required}"

CFG_DIR="$HOME/.claude-bridge"
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config" <<EOF
BRIDGE_PEER=$PEER
BRIDGE_URL=$URL
BRIDGE_TOKEN=$TOKEN
EOF
chmod 600 "$CFG_DIR/config"

# put `bridge` on PATH
HERE="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$HERE/bridge" "$HERE/relay.py"
mkdir -p "$HOME/.local/bin"
ln -sf "$HERE/bridge" "$HOME/.local/bin/bridge"

echo "configured peer='$PEER' url='$URL'"
echo "config written to $CFG_DIR/config (chmod 600)"
echo "symlinked bridge -> ~/.local/bin/bridge"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) echo "NOTE: add ~/.local/bin to PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo "test with:  bridge whoami   &&   bridge ping"
