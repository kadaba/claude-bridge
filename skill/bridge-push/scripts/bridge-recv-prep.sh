#!/usr/bin/env bash
# bridge-recv-prep.sh <dest_dir> — run on the VPS (receiver) to say "I'm ready".
# Creates the destination, reports free space and the SSH target the sender should
# use, so the VPS Claude can reply with a concrete "push here" message.
set -uo pipefail
DEST="${1:?usage: bridge-recv-prep.sh <dest_dir>}"

mkdir -p "$DEST" 2>/dev/null || { echo "RECV_ERROR: cannot create $DEST"; exit 1; }
[ -w "$DEST" ] || { echo "RECV_ERROR: not writable: $DEST"; exit 1; }

user=$(whoami)
host=$(hostname)
# best-effort public/primary IP hint (sender normally uses its own ~/.ssh/config alias)
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "${ip:-}" ] && ip=$(ipconfig getifaddr en0 2>/dev/null || echo "")
free=$(df -Ph "$DEST" 2>/dev/null | awk 'NR==2{print $4" free of "$2}')
rsync_ok=$(command -v rsync >/dev/null 2>&1 && echo yes || echo no)

echo "READY"
echo "dest: $DEST"
echo "ssh_target_hint: ${user}@${host}${ip:+ ($ip)}"
echo "disk: ${free:-unknown}"
echo "rsync_available: $rsync_ok"
echo "accepting: sshd (rsync/tar over SSH)"
