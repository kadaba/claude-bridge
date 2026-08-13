#!/usr/bin/env bash
# bridge-init.sh — set up passwordless SSH from THIS machine to a VPS, from scratch.
# For first-time users who have only a VPS IP + password. Generates an SSH key if
# needed, installs it on the VPS, writes an ~/.ssh/config alias, verifies the
# connection, and saves a bridge target so the skills know where to push.
#
#   Interactive:   ./bridge-init.sh
#   Scripted:      ./bridge-init.sh --host 203.0.113.5 --user root --port 22 \
#                                   --alias vps --app-dir /root/MyApp
#
# Works on macOS and Linux. Safe to re-run (idempotent).
set -uo pipefail

HOST="" USER_="" PORT="22" ALIAS="" APPDIR="" KEY="$HOME/.ssh/id_ed25519"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) USER_="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --alias) ALIAS="$2"; shift 2;;
    --app-dir) APPDIR="$2"; shift 2;;
    --key) KEY="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

ask() { # ask VAR "prompt" "default"
  local __v="$1" __p="$2" __d="${3:-}" __in=""
  if [ -n "${!__v}" ]; then return; fi        # already set via flag
  if [ -n "$__d" ]; then read -r -p "$__p [$__d]: " __in; else read -r -p "$__p: " __in; fi
  printf -v "$__v" '%s' "${__in:-$__d}"
}

echo "== claude-bridge SSH setup =="
ask HOST   "VPS host or IP (e.g. 203.0.113.5 or vps.example.com)"
ask USER_  "SSH user on the VPS" "root"
ask PORT   "SSH port" "22"
ask ALIAS  "Short alias to call it (used as 'ssh <alias>')" "vps"
ask APPDIR "App directory on the VPS (optional, e.g. /root/MyApp)" ""
[ -z "$HOST" ] && { echo "host is required"; exit 1; }

# 1) ensure a key exists ------------------------------------------------------
if [ ! -f "$KEY" ]; then
  echo "-- no SSH key at $KEY; generating an ed25519 key (no passphrase) --"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "claude-bridge@$(hostname)" >/dev/null
  echo "   created $KEY"
else
  echo "-- using existing key $KEY --"
fi
PUB="$(cat "$KEY.pub")"

# 2) install the public key on the VPS ---------------------------------------
echo "-- installing your public key on $USER_@$HOST (you'll enter the VPS password ONCE) --"
installed=0
if command -v ssh-copy-id >/dev/null 2>&1; then
  ssh-copy-id -i "$KEY.pub" -p "$PORT" -o StrictHostKeyChecking=accept-new "$USER_@$HOST" && installed=1
fi
if [ "$installed" -ne 1 ]; then
  echo "   (ssh-copy-id unavailable or failed — using a portable fallback)"
  printf '%s\n' "$PUB" | ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "$USER_@$HOST" \
    'umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo OK' \
    && installed=1
fi
if [ "$installed" -ne 1 ]; then
  echo
  echo "!! Could not install the key automatically (password auth may be disabled)."
  echo "   Paste this line into the VPS's ~/.ssh/authorized_keys via your provider console:"
  echo
  echo "   $PUB"
  echo
  echo "   Then re-run this script."
  exit 1
fi

# 3) write an ~/.ssh/config alias (idempotent) --------------------------------
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
if grep -qiE "^[[:space:]]*Host[[:space:]]+$ALIAS([[:space:]]|$)" "$CFG"; then
  echo "-- ~/.ssh/config already has a 'Host $ALIAS' block; leaving it untouched --"
else
  echo "-- adding 'Host $ALIAS' to ~/.ssh/config --"
  {
    echo ""
    echo "Host $ALIAS"
    echo "    HostName $HOST"
    echo "    User $USER_"
    echo "    Port $PORT"
    echo "    IdentityFile $KEY"
    echo "    ServerAliveInterval 30"
    echo "    ServerAliveCountMax 3"
  } >> "$CFG"
fi

# 4) verify passwordless connection ------------------------------------------
echo "-- verifying passwordless login: ssh $ALIAS --"
if ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" 'echo connected as $(whoami)@$(hostname)'; then
  echo "   SSH OK ✅"
else
  echo "   SSH test failed ❌ — key not accepted. Check the VPS allows key auth."
  exit 1
fi

# 5) save the bridge target so skills/scripts know where to push --------------
TDIR="$HOME/.config/claude-bridge"; mkdir -p "$TDIR"
{
  echo "BRIDGE_SSH_HOST=$ALIAS"
  echo "BRIDGE_REMOTE_DIR=$APPDIR"
} > "$TDIR/target.env"
chmod 600 "$TDIR/target.env"

echo
echo "== done =="
echo "  ssh alias : $ALIAS   (test: ssh $ALIAS true)"
echo "  saved to  : $TDIR/target.env"
[ -n "$APPDIR" ] && echo "  app dir   : $APPDIR (on the VPS)"
echo
echo "Next: start Claude with Remote Control on both machines (claude --rc),"
echo "then ask local Claude to push to '$ALIAS' — the bridge-push skill takes over."
