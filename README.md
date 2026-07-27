# windrose

Self-managing [Windrose](https://playwindrose.com) dedicated game server on AWS.
One-tap **`/start`** from Discord powers it on and posts the invite code; it
**stops itself** when the crew has been gone for a while. Idle cost is just disk
(~$3–5/mo); running cost is ~$10–20/mo at light play — versus ~$220/mo always-on.

```
Discord /start ─▶ API Gateway ─▶ Lambda (windrose-bot) ─▶ ec2:StartInstances
                                                                │
                    ┌───────────────────────────────────────────┘
                    ▼
        EC2 Windows instance (stopped when idle)
          ├─ launch-server.ps1  (at startup): start server, read invite code,
          │                       post "🟢 online + code" to a Discord webhook
          └─ idle-reaper.ps1    (every 5 min): if empty past grace →
                                  post "🔴 shutting down" → Stop-Computer
```

## Layout
| Path | What |
|------|------|
| [PLAN.md](PLAN.md) | Design doc: goals, architecture, cost, risks |
| [infra/](infra/) | Terraform: EC2, Lambda, API Gateway, SSM, IAM (see [infra/README.md](infra/README.md)) |
| [bot/handler.py](bot/handler.py) | Lambda: verifies Discord signatures, routes `/start` `/status` `/stop` |
| [server/](server/) | PowerShell run on the instance: install, launch, idle-reaper |
| [scripts/build_lambda.sh](scripts/build_lambda.sh) | Package the Lambda (PyNaCl + handler) |
| [scripts/register_commands.py](scripts/register_commands.py) | Register the Discord slash commands |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | **Start here to deploy** — full end-to-end steps |
| [docs/RESEARCH-NOTES.md](docs/RESEARCH-NOTES.md) | Verified Windrose server facts + sources |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model, controls, and accepted risks |

## Quick start
Full walkthrough in [docs/RUNBOOK.md](docs/RUNBOOK.md). In short:
```bash
# 1. Create a Discord app (get public key, app id, guild id, bot token, webhook url)
cd infra && cp terraform.tfvars.example terraform.tfvars   # fill these in
# 2. Build + deploy
../scripts/build_lambda.sh && terraform init && terraform apply
# 3. Wire the interactions endpoint URL into Discord, then:
python3 ../scripts/register_commands.py
# 4. RDP once to run server/install-windrose.ps1, capture an AMI, set custom_ami_id
```

## Security
A public HTTPS endpoint that can power hardware on and off deserves more than
"it's just a game server", so the design is written up in
[docs/SECURITY.md](docs/SECURITY.md): trust boundaries, the controls that follow
from them, and every risk knowingly accepted with the reasoning attached.

Short version — no long-lived credentials anywhere (SSM Session Manager, no key
pair, no IAM users); IAM scoped to a single instance ARN where the API allows it;
Ed25519 signature verification before any request body is parsed; IMDSv2
enforced; secrets in SSM `SecureString`; Lambda dependencies hash-pinned with
`pip --require-hashes`, because PyNaCl *is* the authentication boundary here.

`checkov`, `bandit`, and `detect-secrets` run in CI
([workflow](.github/workflows/security.yml)). Suppressions are inline with a
stated reason and expanded in the accepted-risks section.

## Status
Windows v1. A Linux + Docker/Wine v2 (roughly half the compute cost, faster boots,
and a ready-made log parser for exact player counts) is a possible future
optimization once v1 is proven — see the note in [docs/RESEARCH-NOTES.md](docs/RESEARCH-NOTES.md).

## Requirements
Terraform, AWS CLI (any authenticated profile or the default credential chain),
Python 3 + pip. Windows server-side
scripts target PowerShell 5.1 (default on Windows Server 2022).
