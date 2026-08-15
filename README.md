# 🌉 claude-bridge

**Make two AI coding sessions — one on your laptop, one on your VPS — work together as a pair.**

They coordinate over Claude Code's Remote Control (or a bundled relay for any tool),
and move files over SSH with **end-to-end checksum verification** — so *"received"*
means the bytes are provably identical, not just *"sent."*

Free & open source (MIT). Pure Python/Bash stdlib — no heavy dependencies.

```text
You:  "Check if my local app and the VPS copy are the same — if not, merge the best of each."
You:  "Push ./myapp to the VPS."
You:  "What changed between local and prod? Don't touch anything."
```
You type that to your local session. It does the rest.

---

## Highlights
- 🗣️ **Coordinate** — the two sessions talk to each other (Claude Remote Control, or a token-based relay for Codex / Grok / any CLI).
- 📦 **Verified transfer** — one SSH connection: open → transfer → checksum-verify on the far end → close.
- 🔁 **Reconcile** — compare both copies, agree on the best version, deploy, re-verify. Never clobbers `.env` or prod-only files.
- 🔐 **SSH from scratch** — the installer generates a key, installs it, writes the alias. You bring an IP and a password, once.
- 🧩 **Tool-agnostic** — Claude Code, OpenAI Codex, Grok CLI, or anything that runs bash.

## Quick start
```bash
git clone https://github.com/kadaba/claude-bridge.git
cd claude-bridge
./install.sh                 # laptop: installs skills + sets up SSH to your VPS
```
On the VPS: `./install.sh --no-ssh`. Then start each session with `claude --rc`, name
them (`/rename laptop`, `/rename vps`), and just talk to the laptop one.

> **Using Codex or Grok instead of Claude Code?** `./install.sh --agent codex` (or
> `--agent grok`). See [`AGENTS.md`](AGENTS.md) for per-tool install & usage.

<details>
<summary><b>Requirements & what <code>install.sh</code> does</b></summary>

**Requirements:** a Claude subscription signed into both machines · Claude Code on each ·
a VPS you can SSH into (an IP + password is enough to start) · macOS/Linux locally (Windows: WSL).

**`install.sh`** installs the `bridge-push` / `bridge-sync` skills, sets
`crossSessionInbound: accept` so peer messages are delivered, and (on the laptop) runs
`bridge-init.sh` — which generates an `ed25519` key, installs it on the VPS (password once),
writes an `ssh` alias, and verifies passwordless login.
</details>

## See it in action

**"Are they the same? If not, merge the best of each."**
> "Check if my local copy and the VPS copy are the same. If they differ, compare and
> merge so both end up with the best version — don't lose anything."

1. Hashes both trees (local directly; the VPS over SSH).
2. Classifies every file — *identical / local-newer / vps-newer / conflict*.
3. Shows you the diffs, proposes a winner, and **asks before changing anything**.
4. Copies the agreed files each way, checksum-verified — preserving prod-only files like `.env`.

**"Push my code to the VPS."**
> Opens one SSH connection, transfers, verifies every file's checksum on the VPS, closes,
> and reports `VERIFIED ✅` (or retries on mismatch).

**"What's different right now?"** *(read-only)*
> Fingerprints both sides and lists what differs — without touching a thing.

## How it works
```
 laptop ──Remote Control / relay──►  VPS       ← coordination (the conversation)
    │                                  ▲
    └──── SSH: rsync/tar + checksum ───┘        ← the file bytes (verified)
```
Two independent channels: **coordination** is cheap text; **transfer** is verified bytes.

> **Design insight — compare ≠ transfer.** Comparing two copies only exchanges a manifest
> of hashes (a few KB), so it works over almost any channel. Moving the bytes needs a real
> transport. Keeping them separate is why the *compare* still works even on a hostile network.

<details>
<summary><b>The transfer mechanic (for the curious)</b></summary>

`bridge-transfer.sh` opens **one** SSH ControlMaster connection, transfers via `rsync`
(`tar`-over-ssh fallback), computes a checksum manifest on the VPS, compares it to the local
manifest, then closes the connection. Exit `0` = every file verified; exit `1` = mismatch
(rsync resumes on retry). No file counts as *received* until its checksum matches.
</details>

<details>
<summary><b>Optional: shared journal & durable relay</b></summary>

- **Journal (MCP)** — a tiny server exposing `journal_log` / `claim` / `release` so two agents
  never edit the same file at once. A real lock, not a convention. See `journal/`.
- **Relay** — a durable SQLite + HTTP message bus (`relay.py` + `bridge`) for coordination when
  Remote Control isn't available or a peer is offline. It also carries files (`bridge put`/`get`)
  when SSH is blocked. See `systemd/` for the service unit.
</details>

## Works anywhere — other tools, restricted networks, other people

| Situation | Answer |
|---|---|
| **Codex / Grok / other CLI** | Reads [`AGENTS.md`](AGENTS.md) — relay for coordination, SSH scripts for transfer. Bridge across tools, too. |
| **No SSH** | Fall back to a **git remote**, a **cloud bucket**, or `bridge put`/`get` over HTTPS. |
| **Firewalled / behind NAT** | Relay on a neutral host, or a mesh VPN (Tailscale / WireGuard). |
| **Two different people** *(with consent)* | The **token-based relay** — the shared token is the consent gate (Remote Control is same-account only). |

Full details in [`NETWORKING.md`](NETWORKING.md) and [`AGENTS.md`](AGENTS.md).

## Command reference
```bash
# 1. one-time SSH setup
./bridge-init.sh --host YOUR.VPS.IP --user root --alias vps --app-dir /root/myapp

# 2. verified push:  open → transfer → verify → close
skill/bridge-push/scripts/bridge-transfer.sh ./myapp vps /root/myapp        # add --delete to mirror exactly

# 3. fingerprint a tree (compare two copies)
skill/bridge-push/scripts/bridge-manifest.sh ./myapp

# 4. relay: coordination + SSH-free transfer
bridge send --to vps "deploying"     bridge wait --timeout 120
bridge put myapp.tgz                  bridge get myapp.tgz
```

## Security
- Keys are `ed25519`, generated locally; the VPS password is used **once** to install the key, never stored.
- Relay/journal bind to `127.0.0.1` and are reached over the SSH tunnel — nothing is exposed publicly.
- Never overwrites silently · flags secrets (`.env`, keys) before transfer · never deletes remote files without `--delete`.
- **Checksums are the source of truth** — *"sent" ≠ "received."*

## Files
| Path | What |
|---|---|
| `install.sh`, `bridge-init.sh` | one-command setup · SSH-from-scratch wizard |
| `skill/bridge-push/`, `skill/bridge-sync/` | verified file transfer · reconcile an app across machines |
| `relay.py`, `bridge`, `setup.sh`, `systemd/` | message bus + SSH-free file transfer (offline / no-SSH fallback) |
| `journal/` | shared "what was done" ledger with locks (MCP server) |
| `AGENTS.md`, `NETWORKING.md`, `PROTOCOL.md` | multi-tool guide · transports & cross-user · coordination protocol |

## License
MIT — see [LICENSE](LICENSE).
