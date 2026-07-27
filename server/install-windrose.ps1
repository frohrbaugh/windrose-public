<#
.SYNOPSIS
    One-time bootstrap for the Windrose dedicated server on the EC2 Windows box.

.DESCRIPTION
    Run ONCE, as Administrator, over RDP or SSM after the instance first boots.
    It:
      1. Installs AWS CLI (needed by the runtime scripts to read SSM) if missing.
      2. Installs SteamCMD and the Windrose dedicated server (app 4129620), with
         retries (SteamCMD's first app_update often fails "Missing configuration"
         while it self-updates).
      3. Writes the local runtime config (C:\windrose\config\windrose.json).
      4. Copies launch-server.ps1 + idle-reaper.ps1 next to it and registers the
         two scheduled tasks (launch-at-startup, reaper-every-5-min).
      5. Best-effort: first launch to generate ServerDescription.json, then sets
         MaxPlayerCount / ServerName.

    After this succeeds and you've confirmed a launch prints an invite code,
    capture a custom AMI and set custom_ami_id in terraform.tfvars.

.NOTES
    Verified against the real install:
      exe    : <InstallRoot>\R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe
      launch : <InstallRoot>\StartServerForeground.bat  (runs the exe with -log)
      config : <InstallRoot>\R5\ServerDescription.json
               fields are NESTED under .ServerDescription_Persistent
               (InviteCode = 8 hex chars; MaxPlayerCount default 8)
      log    : <InstallRoot>\R5\Saved\Logs\R5.log
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\windrose",
    [string]$SteamCmdDir = "C:\steamcmd",
    [int]$MaxPlayers = 8,
    [string]$ServerName = "Windrose (crew)",
    # Idle-reaper throughput threshold (bytes/sec on the NIC). TUNE during
    # verification: measure empty vs 1-player and set between the two.
    [int]$IdleThresholdBytesPerSec = 2000
)

$ErrorActionPreference = "Stop"
$AppId = "4129620"

# PowerShell 5.1 negotiates SSL3/TLS1.0 by default. Everything below downloads
# over HTTPS, so pin TLS 1.2 before the first request.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

function Assert-Signed {
    <#
      Verify an installer's Authenticode signature before executing it.
      This script pulls binaries off the internet and runs them with SYSTEM
      privileges; TLS proves we reached the right host, not that the bytes are
      the vendor's. Checking the publisher closes the gap between the two.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSubjectMatch
    )
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne "Valid") {
        throw "Refusing to run $Path — Authenticode status is '$($sig.Status)', expected 'Valid'."
    }
    $subject = $sig.SignerCertificate.Subject
    if ($subject -notmatch $ExpectedSubjectMatch) {
        throw "Refusing to run $Path — signed by unexpected publisher: $subject"
    }
    Write-Host "  Signature OK: $subject"
}

# Canonical paths on the install (verified on the real server layout).
$serverExe = Join-Path $InstallRoot "R5\Binaries\Win64\WindroseServer-Win64-Shipping.exe"
$startBat = Join-Path $InstallRoot "StartServerForeground.bat"
$serverCfg = Join-Path $InstallRoot "R5\ServerDescription.json"
$serverLog = Join-Path $InstallRoot "R5\Saved\Logs\R5.log"

# --- 0. Region from instance metadata (IMDSv2) --------------------------------
Write-Step "Detecting region from instance metadata"
$token = Invoke-RestMethod -Method Put -Uri "http://169.254.169.254/latest/api/token" `
    -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "300" }
$Region = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" `
    -Headers @{ "X-aws-ec2-metadata-token" = $token }
Write-Host "Region: $Region"

# --- 1. AWS CLI ---------------------------------------------------------------
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Step "Installing AWS CLI v2"
    $msi = "$env:TEMP\AWSCLIV2.msi"
    Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $msi -UseBasicParsing
    Assert-Signed -Path $msi -ExpectedSubjectMatch "Amazon"
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    $env:Path += ";C:\Program Files\Amazon\AWSCLIV2"
} else {
    Write-Host "AWS CLI already present."
}

# --- 2. SteamCMD + Windrose ---------------------------------------------------
Write-Step "Installing SteamCMD into $SteamCmdDir"
New-Item -ItemType Directory -Force -Path $SteamCmdDir | Out-Null
$steamZip = "$env:TEMP\steamcmd.zip"
# ACCEPTED RISK: Valve ships steamcmd.zip as a rolling download with no published
# checksum or detached signature, so there is nothing to pin it against. The zip
# itself is unsigned; steamcmd.exe inside it is Authenticode-signed by Valve, so
# verify that after extraction. See docs/SECURITY.md.
Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $steamZip -UseBasicParsing
Expand-Archive -Path $steamZip -DestinationPath $SteamCmdDir -Force
Remove-Item $steamZip -Force -ErrorAction SilentlyContinue
Assert-Signed -Path "$SteamCmdDir\steamcmd.exe" -ExpectedSubjectMatch "Valve"

Write-Step "Installing/validating Windrose server (app $AppId) into $InstallRoot"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
# SteamCMD's FIRST app_update commonly fails "Missing configuration" because it
# self-updates mid-run. Retry until the server exe actually appears.
for ($attempt = 1; $attempt -le 4; $attempt++) {
    Write-Host "SteamCMD app_update attempt $attempt of 4..."
    & "$SteamCmdDir\steamcmd.exe" +force_install_dir $InstallRoot +login anonymous +app_update $AppId validate +quit
    if (Test-Path $serverExe) { Write-Host "Server exe present." ; break }
    Write-Warning "Server exe not found yet (likely SteamCMD self-update); retrying in 5s..."
    Start-Sleep 5
}
if (-not (Test-Path $serverExe)) { throw "Windrose install failed: exe missing at $serverExe after 4 SteamCMD attempts." }

# --- 3. Local runtime config --------------------------------------------------
Write-Step "Writing runtime config"
$configDir = Join-Path $InstallRoot "config"
$scriptsDir = Join-Path $InstallRoot "scripts"
$logsDir = Join-Path $InstallRoot "logs"
$stateDir = Join-Path $InstallRoot "state"
$null = New-Item -ItemType Directory -Force -Path $configDir, $scriptsDir, $logsDir, $stateDir

$cfg = [ordered]@{
    Region                   = $Region
    InstallRoot              = $InstallRoot
    ServerExe                = $serverExe
    StartBat                 = $startBat
    ServerConfigPath         = $serverCfg
    ServerLogPath            = $serverLog
    ReaperLogPath            = (Join-Path $logsDir "reaper.log")
    LaunchLogPath            = (Join-Path $logsDir "launch.log")
    ReaperStatePath          = (Join-Path $stateDir "reaper-state.json")
    # Idle detection. Throughput is the default (mode-agnostic). Log parsing is
    # opt-in until the real R5.log line formats are confirmed (see RESEARCH-NOTES).
    IdleThresholdBytesPerSec = $IdleThresholdBytesPerSec
    ThroughputSampleSeconds  = 12
    UseLogParse              = $false
    JoinPattern              = "OnClientIsReady"
    LeavePattern             = "OnAccountUeDisconnected"
    # SSM parameter names (Terraform creates these).
    SsmWebhook               = "/windrose/discord/webhook_url"
    SsmIdleGrace             = "/windrose/reaper/idle_grace_minutes"
    SsmEmptyBootGrace        = "/windrose/reaper/empty_on_boot_grace_minutes"
    # Optional Venmo tip prompt (only exist in SSM when venmo_tip_url is set;
    # the reaper's Get-TipEmbed no-ops when they're absent).
    SsmDonateVenmoUrl        = "/windrose/donate/venmo_url"
    SsmDonateQrUrl           = "/windrose/donate/qr_image_url"
}
$cfg | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $configDir "windrose.json") -Encoding UTF8
Write-Host "Wrote $configDir\windrose.json"

# --- 4. Copy runtime scripts + register scheduled tasks -----------------------
Write-Step "Installing runtime scripts + scheduled tasks"
Copy-Item -Path (Join-Path $PSScriptRoot "launch-server.ps1") -Destination $scriptsDir -Force
Copy-Item -Path (Join-Path $PSScriptRoot "idle-reaper.ps1")   -Destination $scriptsDir -Force

$launchPs = Join-Path $scriptsDir "launch-server.ps1"
$reaperPs = Join-Path $scriptsDir "idle-reaper.ps1"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Launch at startup.
$launchAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$launchPs`""
Register-ScheduledTask -TaskName "Windrose-Launch" -Force -Principal $principal `
    -Action $launchAction -Trigger (New-ScheduledTaskTrigger -AtStartup) | Out-Null

# Reaper every 5 minutes (and shortly after boot).
$reaperAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$reaperPs`""
$reaperTrigger = New-ScheduledTaskTrigger -AtStartup
$reaperTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
Register-ScheduledTask -TaskName "Windrose-IdleReaper" -Force -Principal $principal `
    -Action $reaperAction -Trigger $reaperTrigger | Out-Null
Write-Host "Registered tasks: Windrose-Launch (startup), Windrose-IdleReaper (5 min)."

# --- 5. Generate + patch server config (best effort) --------------------------
Write-Step "Generating ServerDescription.json (first launch, best-effort)"
if (-not (Test-Path $serverCfg)) {
    $p = Start-Process -FilePath $serverExe -WorkingDirectory (Split-Path $serverExe) -ArgumentList "-log" -PassThru
    for ($i = 0; $i -lt 90 -and -not (Test-Path $serverCfg); $i++) { Start-Sleep 2 }
    Start-Sleep 8
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Get-Process -Name "WindroseServer-Win64-Shipping" -ErrorAction SilentlyContinue | Stop-Process -Force
}
if (Test-Path $serverCfg) {
    $sd = Get-Content $serverCfg -Raw | ConvertFrom-Json
    # Fields are nested under ServerDescription_Persistent on the real install.
    $node = if ($sd.ServerDescription_Persistent) { $sd.ServerDescription_Persistent } else { $sd }
    if ($node.PSObject.Properties.Name -contains "MaxPlayerCount") { $node.MaxPlayerCount = $MaxPlayers }
    if ($node.PSObject.Properties.Name -contains "ServerName") { $node.ServerName = $ServerName }
    $sd | ConvertTo-Json -Depth 12 | Set-Content -Path $serverCfg -Encoding UTF8
    # Deliberately not echoing InviteCode — it is the join credential, it is
    # stable across reboots, and setup transcripts get pasted into chats and
    # tickets. launch-server.ps1 delivers it to Discord when the server boots.
    $icLen = if ($node.InviteCode) { $node.InviteCode.Length } else { 0 }
    Write-Host "Set MaxPlayerCount=$MaxPlayers, ServerName='$ServerName'. InviteCode present ($icLen chars, not shown)."
} else {
    Write-Warning "ServerDescription.json not generated. Launch once manually, then set MaxPlayerCount to $MaxPlayers."
}

Write-Step "Done."
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "  1. Verify a launch posts an 8-char invite code to Discord (run: powershell -File $launchPs)" -ForegroundColor Green
Write-Host "     and that '$serverLog' exists. Note the exact join/disconnect log lines for tuning." -ForegroundColor Green
Write-Host "  2. Capture a custom AMI of this instance, then set custom_ami_id in terraform.tfvars." -ForegroundColor Green
Write-Host "  3. Tune IdleThresholdBytesPerSec in $configDir\windrose.json using reaper.log values." -ForegroundColor Green
