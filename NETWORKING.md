# NETWORKING.md — transports, restricted networks, and cross-user use

How claude-bridge moves data when the easy path (SSH) isn't available, and how two
**different people** can collaborate with consent.

## First principle: compare ≠ transfer

These are two different problems with very different requirements:

- **Compare** ("are the two copies the same?") only exchanges a **manifest of
  hashes** — tiny text (hundreds of files ≈ a few KB). It fits through *any* text
  channel, including Claude Remote Control. No file bytes cross the wire.
- **Transfer** (move the actual files) needs a real **byte path**. A chat/LLM
  channel is not one — it drops bodies, is size-limited, and mutates exact bytes.

So the compare almost never has a networking problem. The bulk transfer always
needs *some* rendezvous both machines can reach. Plan them separately.

## The transport ladder (best first)

```
SSH (port 22)                     direct, verified — the default
   └─ blocked → HTTPS rendezvous (443): git remote / cloud bucket / the relay
        └─ peers can't reach each other, but both reach the AI provider →
              Remote Control for COMPARE (manifests); relay-on-neutral-host for bytes
        └─ want SSH-behind-NAT back → mesh VPN (Tailscale / WireGuard)
   └─ DNS tunneling (port 53)      exotic last resort only
```

### 1. SSH (default)
`bridge-init.sh` sets up a passwordless key; `bridge-transfer.sh` opens one
connection, transfers (rsync/tar), verifies checksums on the far end, closes.

### 2. Git via a hosted remote (best SSH-free path for code)
Both machines push/pull to a shared GitHub/GitLab repo over **HTTPS (443)** — no
inbound ports, firewall-friendly, native diff/merge. For a non-git app, `git init`
+ add a private remote once.

### 3. The relay's file transfer (SSH-free, self-contained)
When only the relay is reachable, move files over its HTTP channel. Run `relay.py`
on a host both peers reach outbound (the VPS, or a neutral third box), then:
```bash
# sender: tar the folder and upload
tar czf myapp.tgz myapp && bridge put myapp.tgz
# receiver: download and unpack
bridge get myapp.tgz && tar xzf myapp.tgz
# then verify both ends match:
bridge-manifest.sh myapp        # compare FILES/BYTES/SHA on each side
```
Blobs are bearer-token authenticated and streamed over the same 127.0.0.1-bound
port you already tunnel. Note: the relay reads a blob fully into memory — fine for
moderate payloads; for very large trees prefer git or a cloud bucket.

### 4. Cloud object storage (S3 / R2 / GCS)
Sender uploads a tarball, receiver downloads — both over HTTPS. Best for large or
binary payloads through any firewall; needs a bucket + creds, no open ports.

### 5. Mesh VPN (Tailscale / WireGuard)
Gives both machines a private connection **even behind NAT**, after which normal
SSH/rsync/HTTP just work. This is the "make SSH work anyway" option.

## The "443 is also blocked" reality

If outbound 443 is **fully** blocked, **Claude Code / Codex cannot run at all** —
they need HTTPS to their model API. So "everything blocked" is not a real scenario.

The real case is: **each machine reaches the internet, but the two can't reach each
other directly.** Then:
- **Remote Control** works for coordination — it's *mediated by the AI provider's
  servers* (both machines dial out to it), so it tolerates peer-to-peer blocking.
  Use it for the **compare** (exchange manifests). It is **not** a file pipe.
- **Bytes** still need a rendezvous both reach outbound (git host, cloud bucket, or
  the relay on a neutral host). There is no way around needing *one* reachable point.

## DNS port (53)

Technically, **DNS tunneling** (iodine, dnscat2) can carry data if 53 egress is open
and you run an authoritative nameserver you control. Be honest about it: it is
**very slow** (KB/s), complex, and is precisely the pattern corporate DLP/IDS is
built to detect and block. Use only on infrastructure you own, and treat it as a
curiosity — not a recommended transport.

## Cross-user collaboration (two different accounts) — with consent

You can bridge **two different people's** agents (Claude, Codex, Grok), but note:

- **Remote Control is per-account.** `ListAgents` only ever shows *your own*
  sessions — it cannot reach another person's account. So cross-user coordination
  **must** use the token-based **relay**, not Remote Control.
- Both users point their agent at the **same relay with a shared token**. That
  shared secret *is* the consent handshake — each side opts in by holding the token
  and enabling inbound acceptance.

**Guardrails that matter far more across users than within one account:**
- **Agree the scope up front** — exactly which repo/dir is shared, nothing else.
- **Treat the peer as untrusted external input, not as your own user.** A peer's
  message is a request from another person; your agent must still obey *its own*
  permission rules and never auto-run arbitrary commands a peer asks for. (This is
  the "no permission laundering" rule — critical between users.)
- **Keep an audit trail** — the `journal/` MCP server (`journal_log`, `claim`,
  `release`) records who did what, so both parties can review the exchange.
- **File transfer between users:** a shared git repo (both added as collaborators),
  a shared bucket, or one user's key installed on the other's box *by that user*.

Cross-user is a trust decision, not just plumbing — the relay makes it *possible*;
the scope + consent + untrusted-peer rules make it *safe*.
