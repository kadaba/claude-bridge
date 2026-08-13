#!/usr/bin/env bash
# install-service.sh — install the claude-bridge relay as a user systemd service
# on the VPS, so it auto-starts on boot and restarts on crash.
#
#   ./install-service.sh <TOKEN>
#
# Uses a *user* service (systemctl --user) so it needs no root. To keep it
# running when you're logged out, it enables lingering (needs sudo once).
set -euo pipefail

TOKEN="${1:?usage: install-service.sh <BRIDGE_TOKEN>  (same token both machines use)}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"           # the claude-bridge dir
PYTHON="$(command -v python3)"
UNIT_DIR="$HOME/.config/systemd/user"
ENVFILE="$HOME/.config/claude-bridge.env"

[ -f "$HERE/relay.py" ] || { echo "error: relay.py not found in $HERE"; exit 1; }

# 1) token env file, locked down
mkdir -p "$(dirname "$ENVFILE")"
printf 'BRIDGE_TOKEN=%s\n' "$TOKEN" > "$ENVFILE"
chmod 600 "$ENVFILE"

# 2) render the unit
mkdir -p "$UNIT_DIR"
sed -e "s#__ENVFILE__#$ENVFILE#g" \
    -e "s#__WORKDIR__#$HERE#g" \
    -e "s#__PYTHON__#$PYTHON#g" \
    "$HERE/systemd/claude-bridge.service" > "$UNIT_DIR/claude-bridge.service"

# 3) enable + start
systemctl --user daemon-reload
systemctl --user enable --now claude-bridge.service

# 4) survive logout/reboot without an active session
if command -v loginctl >/dev/null 2>&1; then
  if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    echo "enabling linger (keeps the service up when you're logged out)..."
    sudo loginctl enable-linger "$USER" || \
      echo "WARN: could not enable linger; run: sudo loginctl enable-linger $USER"
  fi
fi

echo
echo "installed. useful commands:"
echo "  systemctl --user status  claude-bridge"
echo "  systemctl --user restart claude-bridge"
echo "  journalctl --user -u claude-bridge -f      # live logs"
echo
echo "verify:  curl -s http://127.0.0.1:8787/health"
