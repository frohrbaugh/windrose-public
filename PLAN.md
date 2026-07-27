# Self-Managing Windrose Dedicated Server on AWS

## Context

Windrose (Early Access, launched April 14 2026) supports free dedicated servers up to 8 co-op
players. Running a server 24/7 on AWS would cost ~$200/mo, but the crew only plays occasionally.
The goal is a **cost-efficient, self-managing** server:

- **Turn ON on demand** via a one-tap `/start` Discord slash command (the host owns the Discord server).
- **Turn OFF automatically** when no players are connected for a grace period.
- **Notify the Discord channel** when the server comes up (with the fresh invite code) and when it
  shuts itself down.

When stopped, cost drops to just disk (~$3–5/mo). This is fully achievable — the two halves
("start on button" + "stop when empty") are a standard game-server pattern, and Windrose's
free SteamCMD server + invite-code matchmaking fit it cleanly.

### Key facts driving the design (from official Windrose dedicated-server guide)
- **Windows-only** server — no Linux/headless build. Must run on a **Windows EC2 instance**.
- Installed free via **SteamCMD, app ID `4129620`, `login anonymous`**. ~35 GB SSD; 16 GB RAM for 8 players.
- Connection modes: **NAT punch-through + 6-char invite code** (default, easiest for players — chosen here)
  or Direct Connection on fixed port 7777. Invite code is printed to the server console on launch and
  **changes each boot** → the boot script must capture and post it to Discord.
- **No documented player-count query / RCON.** Idle detection is therefore done on-box by counting
  active client connections to the server process (network-throughput fallback).

## Architecture

```
Discord (user runs /start)
   │  (HTTPS interaction, Ed25519-signed)
   ▼
API Gateway (HTTP API)  →  Lambda "windrose-bot" (Python)
   │  verifies signature, ec2:StartInstances, acks "⏳ starting (~3 min)"
   ▼
EC2 Windows instance (t3.xlarge, 16 GB, ~40 GB gp3)   ← stopped when idle
   ├─ Boot scheduled task: launch Windrose server, capture invite code,
   │     POST "🟢 online, code: XXXXXX" to Discord webhook
   └─ Idle-reaper scheduled task (every 5 min): count player connections;
         if 0 for grace period → POST "🔴 shutting down, no players" → self-stop
```

**Decoupling note:** Lambda only *starts* the instance and immediately acks. The "ready + invite
code" message comes from the instance itself via a Discord **incoming webhook**, so Lambda never
has to wait on the 2–4 min boot. Self-stop is done by the OS (`Stop-Computer`) with the instance's
shutdown behavior set to `stop` (not terminate) — no self-stop IAM permission needed.

## Components to build

Proposed repo layout. **IaC: Terraform** (clean and repeatable). Plain AWS CLI/CloudFormation is a
viable alternative if preferred. Tooling (git, terraform, aws) runs from WSL on the author's machine,
but nothing in the repo depends on that.

- `infra/` — Terraform:
  - EC2 Windows instance (t3.xlarge, gp3 root ~40 GB), `instance_initiated_shutdown_behavior = "stop"`.
  - Security group: allow Windrose ports; RDP locked to the admin's IP for setup.
  - Lambda `windrose-bot` + IAM role (`ec2:StartInstances`, `StopInstances`, `DescribeInstances`).
  - API Gateway HTTP API → Lambda (public HTTPS endpoint for Discord interactions).
  - SSM Parameter Store (SecureString): Discord **public key**, **bot token**, **webhook URL**, target **instance ID**.
- `bot/handler.py` — Lambda: verify Ed25519 signature (`PyNaCl`), route `/start`, `/status`, `/stop`;
  return deferred/immediate ack. Reads config from SSM.
- `server/install-windrose.ps1` — one-time bootstrap (via EC2 user-data or manual RDP): install SteamCMD,
  `app_update 4129620 validate`, write `ServerDescription.json` (`MaxPlayerCount: 8`), register the two
  scheduled tasks below.
- `server/launch-server.ps1` — **at-startup** task: start the server, tail console log for the invite-code
  line, POST "server online + code" to the Discord webhook (URL pulled from SSM).
- `server/idle-reaper.ps1` — **every-5-min** task: count established client connections owned by the
  Windrose server PID; track idle minutes; on `IDLE_GRACE` (default 15 min) or `EMPTY_ON_BOOT_GRACE`
  (default 20 min, catches "started but nobody joined") → POST shutdown notice → `Stop-Computer -Force`.
- `scripts/register_commands.py` — one-time: register `/start` (+`/status`,`/stop`) guild slash commands
  with Discord.
- `docs/RUNBOOK.md` — Discord app creation, wiring the interactions endpoint URL, first-boot AMI capture,
  resizing, and teardown.

### Reuse / existing setup
- **AWS auth** via an AWS SSO profile (set `aws_profile`, or leave it empty to use the default credential chain)
  for all Terraform/CLI runs; no new keys needed.
- Windrose server binary is **downloaded free from Steam** (no game code to write).
- After first successful install, **capture a custom AMI** so future launches skip SteamCMD download and
  boot straight into a ready server (~2–3 min boots).

## Idle detection — the one real risk, and mitigation
No official player-count API. Primary method: on-box count of active client connections to the server
process (`Get-NetTCPConnection` / `netstat` filtered by the Windrose PID). Fallback: NetworkPackets
throughput threshold over a rolling window (mode-agnostic). Both run in `idle-reaper.ps1`; the grace
periods prevent premature shutdown mid-session and reap forgotten/empty servers. Thresholds are
config values, tuned during verification with a real 1–2 player session.

## Cost (us-east-1 ballpark)
- Running: t3.xlarge **Windows** ≈ ~$0.30/hr → ~$13/mo at ~10 hr/week play.
- Stopped: ~40 GB gp3 ≈ $3.20/mo. NAT/invite-code mode needs **no Elastic IP** → no idle-IP charge.
- Lambda + API Gateway + SSM: effectively $0 at this volume.
- **Total realistic ~$10–20/mo** vs ~$220/mo always-on.

## Verification (end-to-end)
1. `terraform apply`; confirm instance, Lambda, API GW, SSM params created.
2. RDP to instance once, run `install-windrose.ps1`, confirm server launches and prints an invite code;
   capture AMI.
3. In Discord, run `/start` → confirm ack, instance transitions to `running`, and within ~3 min the
   channel gets "🟢 online + invite code".
4. Join from a Windrose client using the posted code (ideally 2 players). Run `/status` → confirm it
   reports running + players present.
5. Everyone disconnects. Within the grace period confirm the channel gets "🔴 shutting down" and the
   instance goes to `stopped` (verify via `aws ec2 describe-instances`).
6. Tune `IDLE_GRACE` / thresholds if shutdown fired too early or too late; re-test.

## Open items to confirm during build
- Terraform vs. plain CLI/CloudFormation (defaulting to Terraform).
- AWS region (default us-east-1; match the crew's location for latency).
- Exact idle grace-period values (start at 15/20 min, tune in step 6).
