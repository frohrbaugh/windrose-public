<#
.SYNOPSIS
    Launch the Windrose server on boot and post "online + invite code" to Discord.

.DESCRIPTION
    Registered by install-windrose.ps1 as the "Windrose-Launch" at-startup task
    (runs as SYSTEM). Every time the instance powers on (including after the
    idle-reaper stops and /start powers it back on) this:
      1. Starts the server process.
      2. Waits for it to be ready and for ServerDescription.json -> InviteCode to
         be populated (authoritative; no fragile console scraping).
      3. Posts "🟢 online, code: XXXXXXXX" to the Discord webhook (read from SSM).
    On failure it posts a warning; the idle-reaper's empty-on-boot grace will
    then stop the instance so it doesn't sit running for nothing.

    NOTE: Windrose nests config fields under "ServerDescription_Persistent"
    (verified on the real install), so the invite code is read from there.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\windrose\config\windrose.json",
    [int]$ReadyTimeoutSeconds = 480,
    [int]$SettleSeconds = 20
)

$ErrorActionPreference = "Stop"

# PowerShell 5.1 still negotiates SSL3/TLS1.0 by default. Pin TLS 1.2 before any
# outbound call (SSM via the CLI, and the Discord webhook POST).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Log($m) {
    $line = "{0}  {1}" -f (Get-Date -Format "u"), $m
    Add-Content -Path $cfg.LaunchLogPath -Value $line
    Write-Host $line
}

function Get-Ssm($name) {
    $aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
    if (-not $aws) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
    & $aws ssm get-parameter --name $name --with-decryption `
        --query "Parameter.Value" --output text --region $cfg.Region
}

function Send-Discord($content) {
    try {
        $webhook = Get-Ssm $cfg.SsmWebhook
        $json = @{ content = $content } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Invoke-RestMethod -Method Post -Uri $webhook -Body $bytes -ContentType "application/json; charset=utf-8" | Out-Null
        Log "Posted to Discord: $content"
    } catch {
        Log "WARN failed to post to Discord: $_"
    }
}

function Get-InviteCode($sd) {
    # Fields live under ServerDescription_Persistent on the real install; fall back to root.
    if ($sd.ServerDescription_Persistent -and $sd.ServerDescription_Persistent.InviteCode) {
        return $sd.ServerDescription_Persistent.InviteCode
    }
    return $sd.InviteCode
}

try {
    Log "Launch task starting."

    # Already running? (e.g. task re-fired) Don't double-launch.
    $running = Get-Process -Name "WindroseServer-Win64-Shipping" -ErrorAction SilentlyContinue
    if (-not $running) {
        if (Test-Path $cfg.ServerConfigPath) {
            $prevWrite = (Get-Item $cfg.ServerConfigPath).LastWriteTimeUtc
        } else {
            $prevWrite = [datetime]::MinValue
        }
        if (Test-Path $cfg.StartBat) {
            Log "Launching via $($cfg.StartBat)"
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$($cfg.StartBat)`"" `
                -WorkingDirectory $cfg.InstallRoot -WindowStyle Hidden
        } else {
            Log "StartBat not found; launching exe directly: $($cfg.ServerExe)"
            Start-Process -FilePath $cfg.ServerExe -WorkingDirectory (Split-Path $cfg.ServerExe) -WindowStyle Hidden
        }
    } else {
        Log "Server already running (PID $($running.Id)); will just read the code."
        $prevWrite = [datetime]::MinValue
    }

    # Wait for readiness: process alive + InviteCode present (and, if the config
    # regenerates each boot, rewritten since we launched).
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $code = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 5
        $proc = Get-Process -Name "WindroseServer-Win64-Shipping" -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        if (-not (Test-Path $cfg.ServerConfigPath)) { continue }
        $sd = Get-Content $cfg.ServerConfigPath -Raw | ConvertFrom-Json
        $ic = Get-InviteCode $sd
        $rewritten = (Get-Item $cfg.ServerConfigPath).LastWriteTimeUtc -gt $prevWrite
        if ($ic -and ($rewritten -or $prevWrite -eq [datetime]::MinValue)) {
            $code = $ic
            break
        }
    }

    if ($code) {
        Start-Sleep $SettleSeconds
        # Re-read after settle in case the code was still being written.
        $sd = Get-Content $cfg.ServerConfigPath -Raw | ConvertFrom-Json
        $ic2 = Get-InviteCode $sd
        if ($ic2) { $code = $ic2 }
        # The invite code IS the join credential and it is stable across reboots,
        # so it does not belong in a plaintext log that survives on the disk.
        # Mask it here; the full code still goes to the Discord channel, which is
        # the audience that actually needs it.
        $masked = if ($code.Length -gt 2) { $code.Substring(0, 2) + ("*" * ($code.Length - 2)) } else { "**" }
        Log "Server ready. Invite code: $masked (full code sent to Discord)"
        Send-Discord "🟢 **Windrose is online!**`nInvite code: ``$code``  ·  join via the in-game *Join Server* → invite code."
    } else {
        Log "ERROR server not ready / no invite code within ${ReadyTimeoutSeconds}s."
        Send-Discord "⚠️ Windrose server started but didn't report an invite code in time. It'll auto-shut-down shortly — try ``/start`` again."
    }
} catch {
    # Full detail goes to the local log only. PowerShell exceptions carry file
    # paths, and sometimes AWS CLI output, which the whole guild can read if
    # posted to the channel.
    Log "FATAL $_"
    Send-Discord "⚠️ Windrose failed to launch. The host has the details in the server log."
    throw
}
