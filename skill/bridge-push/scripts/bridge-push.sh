#!/usr/bin/env bash
# bridge-push.sh <local_path> <ssh_host> <dest_dir> [method] [--delete]
# Run on the SENDER (local) once the VPS has replied "READY, push to <dest>".
# Transfers <local_path> so it lands at <ssh_host>:<dest_dir>/<basename>.
#   method: auto (default) | rsync | tar
#   --delete: make the remote copy EXACTLY match the source (removes extras).
#             Off by default — never deletes remote files unless you ask.
set -uo pipefail

SRC="${1:?usage: bridge-push.sh <local_path> <ssh_host> <dest_dir> [method] [--delete]}"
HOST="${2:?ssh host required}"
DEST="${3:?dest dir required}"
METHOD="${4:-auto}"
DELETE=""
[ "${5:-}" = "--delete" ] && DELETE="--delete"

[ -e "$SRC" ] || { echo "PUSH_ERROR: no such path: $SRC"; exit 1; }
name=$(basename "$SRC")
parent=$(cd "$(dirname "$SRC")" && pwd)

echo "sender: $(hostname)  src: $SRC  ->  $HOST:$DEST/$name"
ssh "$HOST" "mkdir -p '$DEST'" || { echo "PUSH_ERROR: ssh/mkdir failed on $HOST"; exit 1; }

remote_has_rsync() { ssh "$HOST" 'command -v rsync >/dev/null 2>&1'; }

push_rsync() {
  if [ -d "$SRC" ]; then
    rsync -az $DELETE --info=stats1 "$SRC/" "$HOST:$DEST/$name/"
  else
    rsync -az --info=stats1 "$SRC" "$HOST:$DEST/"
  fi
}
push_tar() {
  # "open the connection and take files": stream a tarball over ssh, untar on VPS
  tar cz -C "$parent" "$name" | ssh "$HOST" "mkdir -p '$DEST' && tar xz -C '$DEST'"
}

use=""
case "$METHOD" in
  rsync) use=rsync ;;
  tar)   use=tar ;;
  auto)  if command -v rsync >/dev/null 2>&1 && remote_has_rsync; then use=rsync; else use=tar; fi ;;
  *) echo "PUSH_ERROR: unknown method '$METHOD'"; exit 1 ;;
esac

echo "method: $use${DELETE:+  (--delete)}"
if [ "$use" = rsync ]; then push_rsync; else
  [ -n "$DELETE" ] && echo "note: --delete ignored for tar method"
  push_tar
fi
echo "PUSHED $name -> $HOST:$DEST/$name"
