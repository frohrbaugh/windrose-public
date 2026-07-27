# Windrose Server — Runbook

End-to-end setup, operation, and teardown. Architecture and rationale live in
[../PLAN.md](../PLAN.md); verified game facts in [RESEARCH-NOTES.md](RESEARCH-NOTES.md).

**Flow:** Discord `/start` → API Gateway → Lambda → `ec2:StartInstances`. The
instance boots, launches Windrose, and posts the invite code to a Discord webhook.
A 5-minute reaper stops the instance when it's been empty past the grace period.

---

## 0. Prerequisites (already done on this machine)
- `terraform`, `aws`, `jq`, `python3` + `pip`/`venv` installed.
- Working AWS credentials (`aws sts get-caller-identity`). If you use a named
  SSO profile, set `aws_profile` in `terraform.tfvars` and export
  `AWS_PROFILE=<your-profile>` so the CLI snippets below pick it up.

## 1. Create the Discord application
In the [Discord Developer Portal](https://discord.com/developers/applications):

1. **New Application** → name it (e.g. "Windrose Bot").
2. **General Information** → copy **Application ID** and **Public Key**.
3. **Bot** (left nav) → **Reset Token** → copy the **bot token** (shown once).
4. Get your **Guild ID**: in Discord, enable *Settings → Advanced → Developer Mode*,
   then right-click your server → **Copy Server ID**.
5. Create the **webhook** the server posts to: pick the channel → *Edit Channel →
   Integrations → Webhooks → New Webhook* → **Copy Webhook URL**.
6. **Authorize the app to your server** (required for guild slash commands, else
   registration returns 403 "Missing Access"). Open, pick your server, Authorize:
   `https://discord.com/oauth2/authorize?client_id=<APPLICATION_ID>&scope=applications.commands`

## 2. Fill in Terraform variables
```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```
Edit `terraform.tfvars` with the five Discord values from step 1, and for first-time
RDP set `allowed_rdp_cidr` to your IP (`curl ifconfig.me` → `x.x.x.x/32`) and
`key_pair_name` to an existing EC2 key pair (create one in the console first if needed).
`terraform.tfvars` is gitignored.

## 3. Build the Lambda + apply
```bash
../scripts/build_lambda.sh      # packages PyNaCl + handler.py for the Lambda runtime
terraform init                  # first time only
terraform apply
```
Note the outputs — especially **`interactions_endpoint_url`** and **`instance_id`**.

## 4. Wire the endpoint + register commands
1. Back in the Developer Portal → **General Information** → set **Interactions
   Endpoint URL** to the `interactions_endpoint_url` output → **Save**. Discord
   sends a PING; the Lambda must answer for the save to succeed (it will).
2. Register the slash commands (reads token/app/guild from SSM):
   ```bash
   python3 scripts/register_commands.py
   ```
   `/start`, `/status`, `/stop` appear in your guild immediately.

## 5. First-boot server install (once)
The instance is currently stopped. Start it for setup:
```bash
aws ec2 start-instances --instance-ids <instance_id>
aws ec2 wait instance-running --instance-ids <instance_id>
aws ec2 describe-instances --instance-ids <instance_id> \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text
```
Get the Administrator password (Console → EC2 → the instance → *Connect → RDP client
→ Get password*, using your key pair), then RDP to the public IP.

On the instance (RDP), copy the repo's `server/` folder over (RDP drive redirection
or `git clone`), open **PowerShell as Administrator**, and run:
```powershell
cd <path>\server
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install-windrose.ps1        # installs SteamCMD + Windrose, registers tasks, writes config
```
Then verify a launch and **capture the real log markers**:
```powershell
powershell -File C:\windrose\scripts\launch-server.ps1   # should post an 8-char code to Discord
Get-Content C:\windrose\R5\Saved\Logs\R5.log -Tail 50    # note exact join/disconnect lines
```
If you confirm the join/leave line formats, set `UseLogParse=true` and update
`JoinPattern`/`LeavePattern` in `C:\windrose\config\windrose.json`.

## 6. Capture a custom AMI (fast boots)
With the server installed, capture an image so future boots skip the SteamCMD download:
```bash
aws ec2 create-image --instance-id <instance_id> --name "windrose-ready-$(date +%Y%m%d)" \
  --no-reboot
```
Wait until it's `available`, then set `custom_ami_id` in `terraform.tfvars` and
`terraform apply`. (`instance.tf` has `ignore_changes = [ami]`, so this won't force-replace
a running instance — it applies to the next launch.)

## 7. End-to-end test
1. Ensure the instance is **stopped** (`aws ec2 stop-instances ...`).
2. In Discord run **`/start`** → expect the "⏳ starting" ack, then "🟢 online + code"
   in the channel within ~2–3 min.
3. Join from a Windrose client with the posted code (ideally 2 players).
4. **`/status`** → reports running.
5. Everyone disconnects. Within `idle_grace_minutes` expect "🔴 shutting down" and the
   instance returns to `stopped` (`aws ec2 describe-instances ...`).

## 8. Tuning idle detection
`C:\windrose\logs\reaper.log` prints `bps=<measured>` each run. Compare an **empty**
server vs **1 player**, then set `IdleThresholdBytesPerSec` (in `windrose.json`)
between the two. Adjust grace windows via Terraform (`idle_grace_minutes`,
`empty_on_boot_grace_minutes`) + `terraform apply` (they're stored in SSM, read live).

## Operations
- **Logs on the box:** `C:\windrose\logs\launch.log`, `C:\windrose\logs\reaper.log`,
  `C:\windrose\R5\Saved\Logs\R5.log`.
- **Lambda logs:** CloudWatch group `/aws/lambda/windrose-bot`.
- **Manual control:** `/start` /`/stop`, or `aws ec2 start-instances/stop-instances`.
- **No open RDP after setup:** set `allowed_rdp_cidr = ""` and `terraform apply`; use
  SSM Fleet Manager for occasional admin.
- **Cost:** ~$10–20/mo at light play; ~$3–5/mo (disk) when stopped.

## Teardown
```bash
cd infra && terraform destroy
```
Then delete the Discord application and any AMI/snapshots you captured
(`aws ec2 deregister-image` + `aws ec2 delete-snapshot`), and the EC2 key pair if unused.
