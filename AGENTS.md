# AGENTS.md — using claude-bridge from any AI coding CLI

This repo lets **two AI coding-CLI sessions** — one on your **laptop**, one on your
**VPS** — collaborate: coordinate with each other and move files between the two
machines with checksum verification.

It is **not Claude-only.** Any shell-capable agent works: **Claude Code, OpenAI
Codex, Grok CLI**, or anything that can run bash. Codex reads this `AGENTS.md`
automatically; for other tools, point the agent at this file.

You are one of two peers. Your identity is **`local`** (laptop) or **`vps`**.

## Two independent channels

### 1. Coordination (the conversation)
How the two sessions talk. Pick whichever your tool supports:

- **Claude Code** → native Remote Control (`ListAgents` + `SendMessage`). See
  `skill/bridge-sync/` and `skill/bridge-push/`.
- **Any tool (Codex, Grok, …)** → the **relay**, a neutral HTTP+SQLite message bus.
  Both sessions run `bridge` (a stdlib Python CLI) against one `relay.py` on the VPS:
  ```bash
  bridge send --to vps  "message"      # or --to local
  bridge send --to vps --kind task "do X"
  bridge recv                          # pull new messages
  bridge wait --timeout 300            # block until a reply arrives
  ```
  Setup: run `relay.py` on the VPS, tunnel it (`ssh -N -L 8787:127.0.0.1:8787 vps`),
  and `setup.sh` on each machine. See `README.md` and `PROTOCOL.md`.

`PROTOCOL.md` is the tool-agnostic rulebook for the handshake (identify, hand off a
task, report results, converge). Follow it regardless of which tool you are.

### 2. File transfer (the bytes) — same for every tool
Plain SSH; nothing tool-specific. Scripts in `skill/bridge-push/scripts/`:

- `bridge-init.sh <host> <user> <alias> <app-dir>` — one-time: set up passwordless
  SSH from the laptop to the VPS (generates a key, installs it, writes an alias).
- `bridge-transfer.sh <src> <ssh_host> <dest> [--delete]` — **the atomic op**: opens
  ONE ssh connection, transfers (rsync/tar), verifies every file's checksum on the
  VPS, then closes the connection. Exit 0 = VERIFIED, 1 = MISMATCH.
- `bridge-manifest.sh <path>` — `FILES/BYTES/SHA` fingerprint (compare two copies).
- `bridge-recv-prep.sh <dest>` — VPS side: create dest, report free space.

## Workflows

### Push a folder laptop → VPS
1. Coordinate: tell the peer what you're sending (relay `bridge send`, or Remote
   Control if Claude).
2. Transfer + verify in one shot from the laptop:
   ```bash
   skill/bridge-push/scripts/bridge-transfer.sh ./myapp vps /root/myapp
   ```
   Exit 0 = every file arrived and checksums matched. Exit 1 = re-run (rsync resumes).
3. Tell the peer it's verified.

### Sync an app that exists on both
Compare, agree, then move only what's needed:
1. `bridge-manifest.sh` on each copy → diff the per-file hashes.
2. Classify: local-wins / vps-only-to-preserve / diverged-needs-decision.
3. Agree with the peer on the target (coordination channel). Don't overwrite blindly.
4. Transfer the agreed files; verify with the manifest again.

## Guardrails (all tools)
- **Never overwrite silently.** If the destination exists, confirm first; `--delete`
  only when the user wants an exact mirror.
- **Exclude secrets.** Never transfer `.env`, keys, or `node_modules`/build output
  unless explicitly asked. Flag secrets before moving anything.
- **Checksums are truth.** "Sent" ≠ "received" — only a manifest match closes a transfer.
- **One physical SSH connection per operation**, opened at the start and closed at the
  end (`bridge-transfer.sh` does this via SSH ControlMaster).

## Install & usage by tool

### Claude Code
```bash
./install.sh                 # installs skills + crossSessionInbound + SSH wizard
```
Start `claude --rc` on both machines, name them (`/rename laptop`, `/rename vps`), and talk
to the local session ("push …", "sync …"). Native Remote Control coordinates; relay = fallback.

### OpenAI Codex
```bash
./install.sh --agent codex   # puts 'bridge' on PATH + runs the SSH wizard (no Claude skills)
```
Codex **auto-reads this `AGENTS.md`** from the working directory — so run Codex inside this
repo, or copy the file into your project: `cp AGENTS.md /path/to/project/AGENTS.md`. Then ask:
> "Push ./myapp to the VPS and verify."    "Compare local and the VPS, show me the differences."

Codex runs the SSH scripts via its shell tool. For two Codex sessions to talk, start the relay
(below) and use `bridge send/recv/wait`. The `journal/` MCP server also works — add it as an
MCP server and Codex gets `journal_log` / `claim` / `release`.

### Grok CLI (or any bash-capable agent)
```bash
./install.sh --agent grok    # puts 'bridge' on PATH + runs the SSH wizard
```
Point the agent at `AGENTS.md` (paste it, or place it where your CLI reads project rules). It
needs only a shell tool + the ability to read this file. Ask it the same things — it runs
`bridge-transfer.sh` / `bridge-manifest.sh` for files and `bridge send/recv` to coordinate.

### Start the relay (coordination for Codex / Grok / cross-tool / cross-user)
```bash
# on the VPS (or any host both peers can reach):
export BRIDGE_TOKEN=$(python3 -c "import secrets;print(secrets.token_urlsafe(24))")
python3 relay.py &
# on the laptop:
ssh -N -L 8787:127.0.0.1:8787 vps &
./setup.sh local http://127.0.0.1:8787 "$BRIDGE_TOKEN"    # use 'vps' on the other side
```
Then `bridge send --to vps "…"`, `bridge wait`, `bridge put file`, `bridge get file` work from
any tool. **Same token = connected** — that is also how two *different users* pair (the shared
token is the consent gate; a wrong token is rejected).
