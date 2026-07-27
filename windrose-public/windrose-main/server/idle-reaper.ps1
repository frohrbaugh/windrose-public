<#
.SYNOPSIS
    Stop the instance when the Windrose server has been empty for a grace period.

.DESCRIPTION
    Registered by install-windrose.ps1 as the "Windrose-IdleReaper" task (every
    5 minutes, as SYSTEM). Because Windrose exposes no player-count API, "empty"
    is inferred from NIC throughput by default (mode-agnostic: gameplay generates
    steady inbound traffic regardless of NAT/direct mode). Optionally it also
    parses R5.log join/leave markers (UseLogParse in windrose.json) once their
    real formats are confirmed.

    Two grace windows (values from SSM, set in Terraform):
      * idle_grace_minutes          — after players WERE present then all left.
      * empty_on_boot_grace_minutes — nobody ever joined this boot (forgotten /start).

    On trigger: post "🔴 shutting down" to Discord, then Stop-Computer. The
    instance's shutdown behavior is "stop", so this powers the box off (disk kept).
#>
[CmdletBinding()]
param([string]$ConfigPath = "C:\windrose\config\windrose.json")

$ErrorActionPreference = "Stop"

# PowerShell 5.1 still negotiates SSL3/TLS1.0 by default. Pin TLS 1.2 before the
# SSM reads and the Discord webhook POST below.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Log($m) {
    $line = "{0}  {1}" -f (Get-Date -Format "u"), $m
    Add-Content -Path $cfg.ReaperLogPath -Value $line
}
function NowEpoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Get-Ssm($name, $default) {
    try {
        $aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
        if (-not $aws) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
        $v = & $aws ssm get-parameter --name $name --with-decryption `
            --query "Parameter.Value" --output text --region $cfg.Region 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return $v.Trim() }
    } catch {}
    return $default
}

function Send-Discord($content, $embed = $null) {
    try {
        $webhook = Get-Ssm $cfg.SsmWebhook $null
        if ($webhook) {
            $payload = @{ content = $content }
            if ($embed) { $payload.embeds = @($embed) }
            # Depth >= 4 so the nested embed (image.url) isn't truncated.
            $json = $payload | ConvertTo-Json -Depth 6 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            Invoke-RestMethod -Method Post -Uri $webhook -Body $bytes -ContentType "application/json; charset=utf-8" | Out-Null
        }
    } catch { Log "WARN Discord post failed: $_" }
}

function Get-TipEmbed {
    # Venmo tip embed (or $null if not configured). SSM param names are optional
    # in windrose.json, so guard on their presence too.
    if (-not $cfg.SsmDonateVenmoUrl) { return $null }
    $venmo = Get-Ssm $cfg.SsmDonateVenmoUrl $null
    if (-not $venmo) { return $null }
    $qr = if ($cfg.SsmDonateQrUrl) { Get-Ssm $cfg.SsmDonateQrUrl $null } else { $null }
    $embed = @{
        title       = "Enjoyed the server? Tip the host 🙏"
        description = "This box runs on my dime — if you had fun, a tip keeps it alive.`n**[Open Venmo]($venmo)**"
        color       = 4035022  # 0x3D95CE Venmo blue
    }
    if ($qr) { $embed.image = @{ url = $qr } }
    return $embed
}

function Get-BytesPerSec($seconds) {
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual }
        if (-not $adapters) { return 0 }
        $before = (Get-NetAdapterStatistics -Name $adapters.Name | Measure-Object ReceivedBytes -Sum).Sum
        Start-Sleep -Seconds $seconds
        $after = (Get-NetAdapterStatistics -Name $adapters.Name | Measure-Object ReceivedBytes -Sum).Sum
        return [math]::Round(($after - $before) / $seconds)
    } catch { Log "WARN throughput sample failed: $_"; return 0 }
}

function Get-ClientCount {
    # Established TCP connections to the server from real remote clients
    # (excludes loopback + backend ports 80/443). Robust to AFK players.
    try {
        $procId = (Get-Process -Name "WindroseServer-Win64-Shipping" -ErrorAction SilentlyContinue).Id
        if (-not $procId) { return 0 }
        $conns = Get-NetTCPConnection -OwningProcess $procId -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.RemoteAddress -notin @('127.0.0.1', '::1') -and $_.RemotePort -notin @(80, 443) }
        return @($conns).Count
    } catch { return 0 }
}

# --- Load / reset per-boot state ---------------------------------------------
$bootEpoch = [DateTimeOffset]::new(((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime()).ToUnixTimeSeconds()
$now = NowEpoch

$state = if (Test-Path $cfg.ReaperStatePath) { Get-Content $cfg.ReaperStatePath -Raw | ConvertFrom-Json } else { $null }
if (-not $state -or $state.bootEpoch -ne $bootEpoch) {
    $state = [pscustomobject]@{ bootEpoch = $bootEpoch; lastActiveEpoch = $now; everActive = $false; logOffset = 0; playerCount = 0 }
    Log "New boot detected; state reset."
}

# --- Determine activity -------------------------------------------------------
$serverUp = [bool](Get-Process -Name "WindroseServer-Win64-Shipping" -ErrorAction SilentlyContinue)
$bps = if ($serverUp) { Get-BytesPerSec $cfg.ThroughputSampleSeconds } else { 0 }
$clients = if ($serverUp) { Get-ClientCount } else { 0 }
# Player present if a client TCP connection exists (robust to AFK) OR gameplay
# throughput exceeds the threshold (fallback).
$active = $serverUp -and (($clients -gt 0) -or ($bps -ge $cfg.IdleThresholdBytesPerSec))

if ($serverUp -and $cfg.UseLogParse -and (Test-Path $cfg.ServerLogPath)) {
    try {
        $len = (Get-Item $cfg.ServerLogPath).Length
        if ($state.logOffset -gt $len) { $state.logOffset = 0 }  # log rotated
        $fs = [System.IO.File]::Open($cfg.ServerLogPath, 'Open', 'Read', 'ReadWrite')
        $fs.Seek([long]$state.logOffset, 'Begin') | Out-Null
        $reader = New-Object System.IO.StreamReader($fs)
        $chunk = $reader.ReadToEnd(); $reader.Close(); $fs.Close()
        $state.logOffset = $len
        $joins = ([regex]::Matches($chunk, $cfg.JoinPattern)).Count
        $leaves = ([regex]::Matches($chunk, $cfg.LeavePattern)).Count
        $state.playerCount = [math]::Max(0, $state.playerCount + $joins - $leaves)
        if ($state.playerCount -gt 0) { $active = $true }
    } catch { Log "WARN log parse failed: $_" }
}

if ($active) { $state.lastActiveEpoch = $now; $state.everActive = $true }

# --- Read grace windows + decide ---------------------------------------------
$idleGrace = [int](Get-Ssm $cfg.SsmIdleGrace "15")
$emptyGrace = [int](Get-Ssm $cfg.SsmEmptyBootGrace "20")

$idleMin = [math]::Round(($now - $state.lastActiveEpoch) / 60.0, 1)
$upMin = [math]::Round(($now - $state.bootEpoch) / 60.0, 1)

$shutdown = $false; $reason = ""
if (-not $active) {
    if ($state.everActive -and $idleMin -ge $idleGrace) {
        $shutdown = $true; $reason = "no players for $idleMin min (grace $idleGrace)"
    } elseif (-not $state.everActive -and $upMin -ge $emptyGrace) {
        $shutdown = $true; $reason = "nobody joined in $upMin min since boot (grace $emptyGrace)"
    }
}

$state | ConvertTo-Json -Depth 5 | Set-Content -Path $cfg.ReaperStatePath -Encoding UTF8
Log ("serverUp={0} bps={1} thr={2} clients={3} active={4} ever={5} idleMin={6} upMin={7} logPlayers={8} -> shutdown={9}" -f `
        $serverUp, $bps, $cfg.IdleThresholdBytesPerSec, $clients, $active, $state.everActive, $idleMin, $upMin, $state.playerCount, $shutdown)

if ($shutdown) {
    Log "SHUTTING DOWN: $reason"
    Send-Discord "🔴 **Windrose is shutting down** — $reason. Run ``/start`` to bring it back." (Get-TipEmbed)
    Start-Sleep 3
    Stop-Computer -Force
}
