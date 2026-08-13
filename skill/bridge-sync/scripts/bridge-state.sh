#!/usr/bin/env bash
# bridge-state.sh — emit a compact, comparable snapshot of an app's current state.
# Both peers run this on their own copy; the two outputs are diffed to decide
# what to reconcile. Designed to be small enough to send in one bridge message.
#
#   bridge-state.sh <app_dir> [service_name]
#
# service_name is optional: a systemd unit, pm2 name, or process match string,
# used only to report whether the app is currently running on this host.
set -uo pipefail

APP="${1:?usage: bridge-state.sh <app_dir> [service_name]}"
SVC="${2:-}"
cd "$APP" 2>/dev/null || { echo "STATE_ERROR: no such dir: $APP"; exit 1; }

echo "=== bridge-state ==="
echo "host: $(hostname) ($(uname -s))"
echo "path: $(pwd)"
echo "time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- app version (best-effort) ------------------------------------------------
if [ -f package.json ]; then
  echo "version: $(python3 -c 'import json;print(json.load(open("package.json")).get("version","?"))' 2>/dev/null)"
elif [ -f pyproject.toml ]; then
  echo "version: $(grep -m1 -E '^version' pyproject.toml | sed 's/.*= *//;s/\"//g')"
elif [ -f VERSION ]; then
  echo "version: $(cat VERSION)"
fi

# --- git identity (the reliable comparison key) ------------------------------
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "git.branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "git.head:   $(git rev-parse --short HEAD 2>/dev/null)"
  echo "git.subject:$(git log -1 --pretty=%s 2>/dev/null)"
  echo "git.date:   $(git log -1 --pretty=%cI 2>/dev/null)"
  dirty=$(git status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    echo "git.dirty: YES ($(printf '%s\n' "$dirty" | wc -l | tr -d ' ') files)"
    echo "--- uncommitted changes ---"
    printf '%s\n' "$dirty"
  else
    echo "git.dirty: no"
  fi
  # commits not shared with the peer are found by comparing head/date, but list
  # recent history so the peer can locate a common ancestor:
  echo "--- last 5 commits ---"
  git log -5 --pretty='%h %cI %s' 2>/dev/null
  # remotes matter for the sync strategy
  echo "--- remotes ---"
  git remote -v 2>/dev/null | awk '{print $1, $2}' | sort -u
else
  echo "git: NONE — falling back to file hashes"
  echo "--- file sha256 (top-level source) ---"
  find . -maxdepth 2 -type f \
    \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.jsx' -o -name '*.tsx' \
       -o -name '*.go' -o -name '*.rs' -o -name '*.json' -o -name '*.html' -o -name '*.css' \) \
    ! -path './node_modules/*' ! -path './.git/*' 2>/dev/null | sort | while read -r f; do
      h=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
      printf '%s  %s\n' "${h:0:12}" "$f"
    done
fi

# --- is it running here? ------------------------------------------------------
if [ -n "$SVC" ]; then
  echo "--- service: $SVC ---"
  if command -v systemctl >/dev/null 2>&1 && systemctl status "$SVC" >/dev/null 2>&1; then
    echo "systemd: $(systemctl is-active "$SVC" 2>/dev/null) / $(systemctl is-enabled "$SVC" 2>/dev/null)"
  elif command -v pm2 >/dev/null 2>&1 && pm2 describe "$SVC" >/dev/null 2>&1; then
    echo "pm2: $(pm2 jlist 2>/dev/null | python3 -c 'import sys,json;[print(p["pm2_env"]["status"]) for p in json.load(sys.stdin) if p["name"]=="'"$SVC"'"]' 2>/dev/null)"
  else
    n=$(pgrep -fc "$SVC" 2>/dev/null || echo 0)
    echo "process match '$SVC': $n running"
  fi
fi
echo "=== end ==="
