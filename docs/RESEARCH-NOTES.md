# Windrose Dedicated Server — Research Notes

Findings that drove the implementation. Some are community-sourced (not official),
so **verify against the real install** during first-boot setup. Tagged
`[DOCUMENTED: source]` or `[UNVERIFIED]`.

## ✅ VERIFIED on the real install (deployment 2026-07-11)
Confirmed by actually installing + running the server (supersedes guesses below):
- **Install**: SteamCMD app **4129620**, `login anonymous`, **~2.9 GB** (not 35 GB). The
  **first** `app_update` fails `Missing configuration` while SteamCMD self-updates —
  a retry succeeds (install-windrose.ps1 retries up to 4×).
- **Executable**: `<root>\R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe`.
  `StartServerForeground.bat` runs it with `-log`.
- **Config**: `<root>\R5\ServerDescription.json` — fields are **nested under
  `ServerDescription_Persistent`** (not root). `InviteCode` = **8 hex** (e.g. `0a1b2c3d` — placeholder, never commit a real one),
  **stable across reboots** (not regenerated). `MaxPlayerCount` default **8**.
- **World save**: `<root>\R5\Saved\SaveProfiles\Default\RocksDB_v2\<ver>\Worlds\<id>\`
  (+ `RocksDB_v2_Backups`) — on the EBS disk, so it persists across stop/start.
- **Idle signal** (no player API, as expected): measured **empty ≈ 18–477 B/s**,
  **1 player ≈ 4.5–40 KB/s**. Reaper treats "active" as throughput ≥ **2000 B/s** OR ≥1
  established client TCP connection (excl. loopback + ports 80/443) — the TCP check covers AFK players.
- **Real log markers** (for optional `UseLogParse`): join =
  `R5LogDataKeeper ... OnClientIsReady ... Client id ReadyToPlay. AccountId <id>`;
  leave = `R5LogDataKeeper ... OnAccountUeDisconnected` / `DisconnectAccount ... Reason 'UE disconnect'`
  (also `LogNet: UNetConnection::Close` / `UNetDriver::RemoveClientConnection`).
- **PowerShell 5.1 gotchas**: `.ps1` must be **UTF-8 with BOM** (else emoji break parsing);
  the webhook POST body must be sent as **UTF-8 bytes** (else Discord rejects it, code 50109).

## Corrections to the original PLAN.md
1. **Invite code is 8 hex characters** (e.g. `0a1b2c3d`), not 6. "6" is only an
   enforced *minimum length* if you customize it. [DOCUMENTED: playwindrose.com,
   windrose.wiki.fextralife.com]
2. **Read the code from JSON, don't scrape the console.** The code is persisted in
   `ServerDescription.json` → `InviteCode`, so `launch-server.ps1` reads that
   (authoritative) instead of tailing stdout. [DOCUMENTED: playwindrose, fextralife, xgaming]
3. **There is a real log file**: `<InstallRoot>\R5\Saved\Logs\R5.log`. [DOCUMENTED: xgamingserver.com]

## Install / launch
- SteamCMD, **app ID `4129620`**, `login anonymous`, no purchase. [DOCUMENTED: playwindrose, hub.tcno.co]
  (The *game's* Steam app is a different ID; 4129620 is the free server tool.)
- Executable: **`WindroseServer-Win64-Shipping.exe`** in `R5\Binaries\Win64\`. [DOCUMENTED: hub.tcno.co]
- Launch via **`StartServerForeground.bat`** at the install root. [DOCUMENTED: playwindrose, fextralife]
- **No command-line arguments** — all config via `ServerDescription.json`. [DOCUMENTED]

## Config: `ServerDescription.json` (in the `R5` folder)
- Edit only while the server is stopped. [DOCUMENTED: multiple]
- Fields: `PersistentServerId` (auto), `InviteCode`, `IsPasswordProtected`/`Password`,
  `ServerName`, `WorldIslandId`, **`MaxPlayerCount`**, `P2pProxyAddress`, and direct-mode
  fields `UseDirectConnection`/`DirectConnectionServerPort`/…. [DOCUMENTED: xgaming; direct-mode fields disputed by fextralife — verify locally]
- Max player cap reported inconsistently as **8 vs 10**; recommended value 4 in EA. We use 8. [UNVERIFIED exact cap]

## Idle detection (the real risk)
- **No RCON, no HTTP status endpoint, no built-in auto-shutdown.** [DOCUMENTED-as-absent across all sources]
- The server logs connection activity to `R5.log` with markers like
  **`Login request`** and **`p2pgate disconnected`** (and `R5LogDataKeeper`). Exact
  join/leave line formats are **not officially published** — the community Docker
  project calls its own parsing "best-effort." [DOCUMENTED: github.com/UberDudePL/windrose-dedicated-server-docker]
- **Our approach:** `idle-reaper.ps1` defaults to **NIC throughput** (mode-agnostic,
  no format assumptions). Log parsing is opt-in (`UseLogParse` in `windrose.json`)
  once the real markers are confirmed from a live `R5.log`. Capture those markers
  during first-boot verification and tune `IdleThresholdBytesPerSec`.

## Ports / networking
- **Default = NAT punch-through + invite code**: no fixed inbound port; router UPnP
  recommended (irrelevant on EC2 — outbound punch-through works). No inbound game
  port needed. [DOCUMENTED: playwindrose, fextralife]
- **Direct Connection mode**: single port (default **7777**), TCP **and** UDP.
  Existence disputed by one source — verify against your installed config. [DOCUMENTED: playwindrose, hub.tcno.co]

## Sources
- https://playwindrose.com/dedicated-server-guide/ (official)
- https://windrose.wiki.fextralife.com/Dedicated_Server_Guide (community wiki)
- https://hub.tcno.co/games/windrose/dedicated_server/ (TroubleChute)
- https://xgamingserver.com/docs/windrose/server-config and /troubleshooting
- https://github.com/UberDudePL/windrose-dedicated-server-docker (+ TROUBLESHOOTING.md) — also the reference for a future Docker/Wine v2
