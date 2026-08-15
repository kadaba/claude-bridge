# claude-bridge

**Let two Claude Code sessions — one on your laptop, one on your VPS — work together.**
They talk over Claude's built-in Remote Control, and move files over SSH with
end-to-end checksum verification. Free and open source (MIT).

- 🗣️ **Talk:** the two sessions coordinate natively (no server to run for chat).
- 📦 **Push files:** open one SSH connection → transfer → verify every file arrived → close.
- 🔁 **Sync an app:** compare both copies, agree on the best version, deploy, verify.
- 🧾 **No confusion:** an optional shared journal (MCP) with real locks records who did what.

Everything is plain Python/Bash stdlib — no heavy dependencies.

---

## Requirements
- A Claude subscription (Pro / Max / Team / Enterprise) signed into **both** machines.
- Claude Code installed on your laptop and your VPS.
- A VPS you can SSH into (the installer sets SSH up from scratch — you only need the
  IP and a password to start).
- macOS or Linux locally (Windows: use WSL).

## Install (both machines)
```bash
git clone https://github.com/<you>/claude-bridge.git
cd claude-bridge
./install.sh          # on your laptop — installs skills, opts into peer messages, sets up SSH
```
On the **VPS**, run it without the SSH wizard (the VPS is the destination, not the sender):
```bash
./install.sh --no-ssh
```

`install.sh` will:
1. Install the `bridge-push` and `bridge-sync` skills into `~/.claude/skills/`.
2. Set `crossSessionInbound: accept` so peer messages are delivered.
3. (Laptop) run **`bridge-init.sh`** to set up passwordless SSH to your VPS.

### SSH from scratch (what `bridge-init.sh` does)
No pre-existing SSH keys or config required. It:
- generates an `ed25519` key if you don't have one,
- copies the public key to your VPS (you type the VPS password **once**),
- writes an `~/.ssh/config` alias so `ssh <alias>` just works,
- verifies passwordless login,
- saves the target so the skills know where to push.

Run it standalone any time:
```bash
./bridge-init.sh --host 203.0.113.5 --user root --alias vps --app-dir /root/MyApp
# or just: ./bridge-init.sh   (it asks for each value)
```

## Use it
1. On **both** machines, start Claude with Remote Control:
   ```bash
   claude --rc
   ```
   (Or enable **"Remote Control for all sessions"** in `/config` once, then plain `claude`.)
2. Give each session a clear name so you can tell them apart: in the session, run
   `/rename laptop` (and `/rename vps` on the other). Confirm they see each other —
   ask one to run `ListAgents`.
3. Then just talk to your laptop session:
   - **"Push ./myapp to the VPS"** → `bridge-push` opens SSH, transfers, verifies, closes.
   - **"Sync myapp with the VPS"** → `bridge-sync` reconciles both copies to the best version.

## Examples

**1. First-time SSH setup (once, from the laptop)**
```bash
./bridge-init.sh --host YOUR.VPS.IP --user root --alias vps --app-dir /root/myapp
# enter your VPS password once → it installs a key and writes an 'ssh vps' alias
```

**2. Push a folder to the VPS — open → transfer → verify → close (one command)**
```bash
skill/bridge-push/scripts/bridge-transfer.sh ./myapp vps /root/myapp
# → VERIFIED ✅ all files transferred to vps:/root/myapp, checksums match   (exit 0)
```
Make the remote an exact mirror (also deletes remote extras):
```bash
skill/bridge-push/scripts/bridge-transfer.sh ./myapp vps /root/myapp --delete
```

**3. Compare two copies without moving anything**
```bash
skill/bridge-push/scripts/bridge-manifest.sh ./myapp          # local fingerprint
ssh vps 'cd /root/myapp && find . -type f ! -path "./.git/*" | sort | xargs sha256sum | sha256sum'
# matching FILES/BYTES/SHA on both sides = identical trees
```

**4. Coordinate the two sessions over the relay (works with any CLI — Codex, Grok, …)**
```bash
# on the VPS — start the message bus:
export BRIDGE_TOKEN=$(python3 -c "import secrets;print(secrets.token_urlsafe(24))")
python3 relay.py &                          # listens on 127.0.0.1:8787

# on the laptop — tunnel + configure:
ssh -N -L 8787:127.0.0.1:8787 vps &
./setup.sh local http://127.0.0.1:8787 "$BRIDGE_TOKEN"

# then, from either side:
bridge send --to vps "starting deploy of myapp"
bridge wait --timeout 120                   # block until the peer replies
```

**5. What you actually say to the agent (Claude Code)**
Just talk to your local session — the skills do the handshake, transfer, and verify:
> "Push ./myapp to the VPS."
> "Sync myapp between local and the VPS, keep the best version."

## Example conversations (what you actually say)

Once both sessions are connected, you just talk to your **local** Claude Code in
plain English. Here are real scenarios.

### "Are both versions the same? If not, compare and merge the best of each."
> **You:** "Check if my local copy of the app and the one on the VPS are the same.
> If they differ, compare them and merge so both end up with the best version —
> don't lose anything."

**What it does:**
1. Reads your local files and asks the VPS session for its file checksums.
2. Diffs the two and classifies every file: *identical* / *local is newer* /
   *VPS is newer* / *both changed (conflict)*.
3. Shows you the differences for anything that diverged and proposes which side
   wins (or a merge), then **asks you to confirm** — it won't guess silently.
4. On your OK, copies the agreed files each direction over SSH (checksum-verified),
   so both machines end up identical to the agreed "best" version.
5. Confirms both sides now match, and **preserves VPS-only files** like `.env`.

### "Push my latest code to the VPS."
> **You:** "Push my local ./myapp to the VPS."

**What it does:** opens one SSH connection, transfers, verifies every file's
checksum on the VPS, closes the connection, and reports `VERIFIED ✅` (or retries
on mismatch). Your `.env` and secrets are never overwritten unless you say so.

### "What's different between the two right now?" (read-only)
> **You:** "Just tell me what's different between my local app and the VPS — don't
> change anything."

**What it does:** fingerprints both copies and shows you a list — files only on one
side, files that changed, and which is newer — without touching a thing.

### "Deploy this update safely to the running app."
> **You:** "I changed the auth code locally. Update the VPS, but don't break what's
> running — check with the VPS side first."

**What it does:** compares state, flags if the VPS has uncommitted changes or a
hotfix, agrees on the target with you, transfers, then restarts/verifies — treating
the running VPS copy as production.

> Tip: give each session a clear name first (`/rename laptop`, `/rename vps`) so you
> always know which is which.

## How it works
```
 laptop Claude ──Remote Control (SendMessage)──►  VPS Claude     ← the conversation
        │                                            ▲
        └──────── SSH: rsync/tar + checksum ─────────┘           ← the file bytes
```
- **Coordination** rides Claude's Remote Control — nothing to host.
- **Bytes** ride SSH. `bridge-transfer.sh` runs one `ssh` ControlMaster connection,
  transfers (rsync, or tar-over-ssh as a fallback), computes a checksum manifest on
  the VPS, compares it to the local manifest, then closes the connection. "Received"
  means the checksums matched — not just "sent".
- **Optional shared journal** (`journal/`): one small MCP server on the VPS gives both
  sessions `journal_log` / `claim` / `release` tools so two Claudes never edit the same
  thing at once. See `journal/setup-journal.sh`.
- **Optional durable relay** (`relay.py` + `bridge`, `systemd/`): a fallback message bus
  for when a peer session is offline. Not needed for the Remote Control path.

## Works with Codex, Grok, and other CLIs
claude-bridge is really two independent parts, and only the coordination half is
Claude-specific:
- **File transfer is tool-agnostic** — `bridge-init.sh` / `bridge-transfer.sh` /
  `bridge-manifest.sh` are plain SSH + shell. Any agent that can run bash uses them.
- **Coordination** is Claude's Remote Control by default, but the bundled **relay**
  (`relay.py` + `bridge`) is a neutral message bus any CLI can use over shell.

So the same repo works for **Claude Code, OpenAI Codex, and Grok CLI**:
- **Codex** reads [`AGENTS.md`](AGENTS.md) automatically — relay for coordination, the
  SSH scripts for transfer, and the optional `journal/` MCP server.
- **Grok / others** — point the agent at `AGENTS.md`; if it can run bash it can drive
  the relay + SSH scripts.
- You can even bridge **across** tools (a Claude session ↔ a Codex session), since the
  relay and SSH protocol are neutral.

See [`AGENTS.md`](AGENTS.md) for the tool-agnostic instructions.

## Security
- SSH keys are `ed25519`, generated locally; your VPS password is used only once to
  install the public key and never stored.
- The journal/relay bind to `127.0.0.1` and are reached over the SSH tunnel — nothing
  is exposed to the public internet.
- `bridge-push` refuses to overwrite silently and flags secrets (`.env`, keys) before
  transfer. It never deletes remote files unless you pass `--delete`.

## Files
| Path | What |
|---|---|
| `install.sh` | one-command setup for a machine |
| `bridge-init.sh` | SSH-from-scratch wizard (keys, key-copy, config alias, verify) |
| `skill/bridge-push/` | skill + scripts: transfer files with verification |
| `skill/bridge-sync/` | skill + scripts: reconcile an app across both machines |
| `journal/` | optional shared "what was done" ledger as an MCP server |
| `relay.py`, `bridge`, `systemd/` | optional durable offline-fallback message bus |

## License
MIT — see [LICENSE](LICENSE).
