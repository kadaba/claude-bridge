#!/usr/bin/env bash
# bridge-transfer.sh <local_path> <ssh_host> <dest_dir> [--delete]
#
# The atomic byte-path, run on the SENDER (local) after the VPS Claude has said
# "push to <dest>, I'm ready". It:
#   1. opens ONE ssh connection (ControlMaster),
#   2. transfers <local_path> -> <ssh_host>:<dest_dir>/<basename> (rsync or tar),
#   3. verifies EVERY file arrived (remote checksum manifest == local manifest),
#   4. CLOSES the ssh connection,
#   5. exits 0 (VERIFIED) or 1 (MISMATCH) so the caller can continue or retry.
#
# One physical SSH connection is opened at the start and closed at the end.
set -uo pipefail

SRC="${1:?usage: bridge-transfer.sh <local_path> <ssh_host> <dest_dir> [--delete]}"
HOST="${2:?ssh host required}"
DEST="${3:?dest dir required}"
DEL=""
[ "${4:-}" = "--delete" ] && DEL="--delete"

[ -e "$SRC" ] || { echo "TRANSFER_ERROR: no such path: $SRC"; exit 1; }
name=$(basename "$SRC")
parent=$(cd "$(dirname "$SRC")" && pwd)
here="$(cd "$(dirname "$0")" && pwd)"

# ---- 0. local fingerprint --------------------------------------------------
LOCAL=$("$here/bridge-manifest.sh" "$SRC") || { echo "TRANSFER_ERROR: local manifest failed"; exit 1; }

# ---- 1. open ONE ssh connection (short socket path: unix sockets cap ~104ch)-
SOCK="/tmp/bridge-ssh-$$.sock"
closed=0
close_ssh() { [ "$closed" = 1 ] && return; ssh -S "$SOCK" -O exit "$HOST" 2>/dev/null; closed=1; }
trap close_ssh EXIT
echo "opening ssh connection to $HOST ..."
ssh -M -S "$SOCK" -o ControlPersist=30 -o ConnectTimeout=10 -fN "$HOST" \
  || { echo "TRANSFER_ERROR: cannot open ssh to $HOST (check `ssh $HOST true`)"; exit 1; }
SOPT=(-o ControlPath="$SOCK")

# ---- 2. ensure dest + transfer over the shared connection ------------------
ssh "${SOPT[@]}" "$HOST" "mkdir -p '$DEST'" || { echo "TRANSFER_ERROR: mkdir on remote failed"; exit 1; }

if command -v rsync >/dev/null 2>&1 && ssh "${SOPT[@]}" "$HOST" 'command -v rsync >/dev/null 2>&1'; then
  echo "transfer: rsync${DEL:+ (--delete)}"
  if [ -d "$SRC" ]; then
    rsync -az $DEL -e "ssh -o ControlPath=$SOCK" "$SRC/" "$HOST:$DEST/$name/" || { echo "TRANSFER_ERROR: rsync failed"; exit 1; }
  else
    rsync -az -e "ssh -o ControlPath=$SOCK" "$SRC" "$HOST:$DEST/" || { echo "TRANSFER_ERROR: rsync failed"; exit 1; }
  fi
else
  echo "transfer: tar-over-ssh"
  [ -n "$DEL" ] && echo "note: --delete ignored on tar path"
  tar cz -C "$parent" "$name" | ssh "${SOPT[@]}" "$HOST" "tar xz -C '$DEST'" || { echo "TRANSFER_ERROR: tar transfer failed"; exit 1; }
fi

# ---- 3. remote fingerprint (inline; needs only find + sha256sum/shasum) -----
REMOTE=$(ssh "${SOPT[@]}" "$HOST" "bash -s '$DEST/$name'" <<'REMOTE_EOF'
D="$1"
sha(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
if [ -f "$D" ]; then sz=$(wc -c < "$D"|tr -d ' '); h=$(sha < "$D"|awk '{print $1}'); echo "FILES=1 BYTES=$sz SHA=$h"; exit 0; fi
cd "$D" 2>/dev/null || { echo "MANIFEST_ERROR: no such dir: $D"; exit 1; }
lines=$(find . -type f ! -path './.git/*' | LC_ALL=C sort | while IFS= read -r f; do sz=$(wc -c < "$f"|tr -d ' '); h=$(sha < "$f"|awk '{print $1}'); printf '%s\t%s\t%s\n' "$f" "$sz" "$h"; done)
files=$(printf '%s' "$lines"|grep -c . || true)
bytes=$(printf '%s\n' "$lines"|awk -F'\t' '{s+=$2} END{printf "%d", s+0}')
combined=$(printf '%s' "$lines"|sha|awk '{print $1}')
echo "FILES=$files BYTES=$bytes SHA=$combined"
REMOTE_EOF
)

# ---- 4. close the ssh connection (explicit; trap is a backstop) ------------
close_ssh
trap - EXIT
echo "ssh connection closed."

# ---- 5. verdict ------------------------------------------------------------
echo "local : $LOCAL"
echo "remote: $REMOTE"
if [ "$LOCAL" = "$REMOTE" ]; then
  echo "VERIFIED ✅ all files transferred to $HOST:$DEST/$name, checksums match."
  exit 0
fi
echo "MISMATCH ❌ transfer incomplete or altered. Re-run (rsync resumes)."
exit 1
