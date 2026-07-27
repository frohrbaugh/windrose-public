# Security notes

The threat model for this project, the controls that follow from it, and the
risks knowingly accepted. Automated scanners (`checkov`, `bandit`,
`detect-secrets`) run in CI; where a finding is suppressed, the reason is inline
at the suppression and expanded here.

## What this thing actually is

A Discord slash command that powers a Windows EC2 instance on and off, plus
scripts on the instance that announce the game server's invite code and shut the
box down when nobody is playing. Single maintainer, a handful of players, no
customer data, no compliance regime.

That shapes the whole document: the goal is proportionate engineering, not
maximum controls. Several checks are suppressed on purpose, and the reasoning
matters more than the count of green ticks.

## Trust boundaries

| Boundary | Who is on the far side | What holds |
|---|---|---|
| `POST /interactions` | The entire internet | Ed25519 signature verification against the Discord app public key, before the body is parsed. Unsigned or mis-signed requests get a 401 and never reach any AWS call. |
| Discord guild | Anyone the owner invited | No per-user authorization. Any guild member can `/start` and `/stop`. Accepted — see below. |
| Instance → AWS | The instance role | Scoped to `ssm:GetParameter*` on `/windrose/*` and `kms:Decrypt` conditioned on `kms:ViaService = ssm`. No EC2 mutation rights at all. |
| Lambda → AWS | The function role | `ec2:StartInstances`/`StopInstances` scoped to one instance ARN. `Describe*` is `*` because the EC2 API does not support resource-level scoping for it. |
| Game port | Players | Closed by default. The default NAT punch-through + invite-code path needs no inbound rule. `open_game_port` exists for direct connection and is opt-in. |

## Controls worth naming

**Identity and access**
- No long-lived credentials anywhere. No IAM users, no access keys, no key pair
  required — the instance is administered through SSM Session Manager.
- Every IAM policy is written by hand and resource-scoped where the API permits.
- RDP (3389) has no rule at all unless `allowed_rdp_cidr` is set, and the
  variable's documented form is a `/32`.

**Data**
- Discord webhook URL and bot token live in SSM as `SecureString`; the Terraform
  variables carrying them are marked `sensitive`.
- Root EBS volume encrypted.
- `terraform.tfvars`, all state files, and saved plan files are gitignored —
  plans in particular serialize secret values in the clear.
- The Venmo QR is gitignored rather than committed: it encodes a personal
  payment identity, which is fine to hand to players at runtime and wrong to
  publish in a repository.
- The invite code is treated as a credential. It is stable across reboots, so it
  is masked in the instance log and never echoed by the installer; it is
  delivered only to the Discord channel that needs it.

**Instance**
- IMDSv2 required, hop limit 1. The instance role can read Discord secrets, so
  an SSRF in anything running on the box must not be able to walk to
  `169.254.169.254` and lift them.
- Installers are Authenticode-verified against the expected publisher before
  execution. TLS 1.2 is pinned; PowerShell 5.1 will otherwise negotiate down.

**Supply chain**
- Lambda dependencies are hash-pinned and the pins are enforced with
  `pip --require-hashes`. PyNaCl performs the signature verification that is
  this bot's only authentication, so a substituted wheel is an authentication
  bypass rather than a broken build.
- The Terraform provider lock file is committed.

**Blast radius and audit**
- Lambda reserved concurrency and API Gateway throttling cap what a request
  flood against the public endpoint can cost. Forged requests are rejected, but
  rejecting one still bills an invocation.
- API Gateway access logging is on, deliberately excluding request bodies:
  Discord payloads carry usernames and command arguments, and none of that needs
  to be durably stored to run a game server.
- Log groups are declared explicitly with bounded retention. Left implicit, they
  default to never expiring.

## Accepted risks

**Any guild member can start and stop the server.** There is no per-user
authorization check. The blast radius is a few dollars of EC2 time and an
interrupted game, the guild is invite-only, and the alternative is a role-check
that the owner would have to maintain by hand. Revisit if the guild ever opens up.

**The QR object in S3 is publicly readable.** Discord fetches embed images
anonymously from its own infrastructure, so there is no presigned-URL path that
stays valid for an arbitrarily old embed. The grant is narrowed as far as it
goes: one named object key rather than `/*`, ACLs blocked in both directions,
plaintext HTTP denied, and the whole bucket only exists when the tip feature is
switched on. Suppresses `CKV_AWS_54`, `CKV_AWS_56`.

**`steamcmd.zip` cannot be pinned.** Valve publishes it as a rolling download
with no checksum and no detached signature, so there is nothing to verify the
archive against. The mitigation is to Authenticode-verify `steamcmd.exe` after
extraction and to confine the whole thing to a disposable instance with no
credentials beyond SSM read access.

**Unauthenticated API Gateway route.** Discord cannot present SigV4 or a JWT, so
a gateway-level authorizer is not an option. Authentication happens one layer in,
in the Lambda, before the payload is parsed. Suppresses `CKV_AWS_309`.

**Egress is unrestricted.** The instance needs Steam CDN, Windows Update, the
SSM endpoints, and Discord. Enumerating and maintaining that set of prefixes for
a game server is not worth the effort. Suppresses `CKV_AWS_382`.

**Terraform state is local and unencrypted at rest.** Single maintainer, no
concurrent applies, no locking needed. State contains the SSM parameter values,
so the file is gitignored and should live on an encrypted disk. A remote S3
backend with DynamoDB locking is the obvious upgrade if anyone else ever touches
this.

**SSM `SecureString` uses the AWS-managed key, not a CMK.** A customer-managed
key would add key-policy control and rotation visibility for roughly a dollar a
month. Deliberate omission at this scale rather than an oversight. Suppresses
`CKV_AWS_337`, `CKV2_AWS_34`.

**No DLQ, no X-Ray, no VPC, no code signing on the Lambda.** Three code paths
and a worst case of a dropped chat reply. CloudWatch logs are sufficient to debug
it, and a VPC would add NAT cost for a function that only calls the public EC2
API. Suppresses `CKV_AWS_116`, `CKV_AWS_50`, `CKV_AWS_117`, `CKV_AWS_272`.

## Running the scans

```bash
pip install checkov bandit detect-secrets
checkov -d infra --compact          # IaC
bandit -r bot/ scripts/             # Python
detect-secrets scan --baseline .secrets.baseline
```

CI runs all three on every push and pull request (`.github/workflows/security.yml`).

Note that no scanner in this set would have caught the two things that actually
mattered before the first cleanup pass: a real payment QR committed as a binary,
and a live invite code sitting in a documentation example. Automated scanning is
a floor, not a substitute for reading your own diff.

## Reporting

It is a game server. Open an issue.
