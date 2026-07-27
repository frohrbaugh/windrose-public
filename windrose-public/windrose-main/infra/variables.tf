# ---------------------------------------------------------------------------
# AWS / region
# ---------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = <<-EOT
    Local AWS CLI/SSO profile Terraform authenticates with. Leave empty to use
    the default credential chain (env vars, default profile, instance role).
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type. t3.xlarge = 4 vCPU / 16 GB, sized for 8 players."
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_gb" {
  description = "Root gp3 volume size (GB). Windows + SteamCMD + Windrose (~35 GB) needs headroom."
  type        = number
  default     = 50
}

variable "custom_ami_id" {
  description = <<-EOT
    AMI to launch. Leave empty to use the latest Windows Server 2022 Base AMI
    (for the first install). After you install Windrose and capture a custom AMI,
    set this to that AMI ID so future launches boot straight into a ready server.
  EOT
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = <<-EOT
    Name of an existing EC2 key pair, used to decrypt the Windows Administrator
    password for RDP during first-time setup. Optional — leave empty to rely on
    SSM Session Manager / Fleet Manager instead (no key pair, no open RDP port).
  EOT
  type        = string
  default     = ""
}

variable "allowed_rdp_cidr" {
  description = <<-EOT
    CIDR allowed to RDP (3389) to the instance for setup, e.g. "203.0.113.7/32".
    Leave empty to keep RDP fully closed and administer via SSM Fleet Manager only.
  EOT
  type        = string
  default     = ""
}

variable "open_game_port" {
  description = <<-EOT
    Whether to open the Windrose Direct-Connection game port (see game_port) to the
    internet. Not needed for the default NAT punch-through + invite-code mode.
  EOT
  type        = bool
  default     = false
}

variable "game_port" {
  description = "Windrose Direct-Connection port (only used if open_game_port = true)."
  type        = number
  default     = 7777
}

# ---------------------------------------------------------------------------
# Discord
# ---------------------------------------------------------------------------
variable "discord_public_key" {
  description = "Discord application PUBLIC KEY (hex). Used by Lambda to verify interaction signatures. Not secret."
  type        = string
}

variable "discord_bot_token" {
  description = "Discord bot token. Used only to register slash commands. Stored as SSM SecureString."
  type        = string
  sensitive   = true
}

variable "discord_webhook_url" {
  description = "Discord incoming webhook URL the server posts online/offline messages to. Stored as SSM SecureString."
  type        = string
  sensitive   = true
}

variable "discord_application_id" {
  description = "Discord application (client) ID. Used for slash-command registration."
  type        = string
}

variable "discord_guild_id" {
  description = "Discord server (guild) ID where the slash commands are registered."
  type        = string
}

# ---------------------------------------------------------------------------
# Idle-reaper tuning (passed to the instance via SSM for the reaper script)
# ---------------------------------------------------------------------------
variable "idle_grace_minutes" {
  description = "Minutes with zero players before the server shuts itself down."
  type        = number
  default     = 15
}

variable "empty_on_boot_grace_minutes" {
  description = "Minutes after boot with no one ever joining before self-shutdown (catches 'started but nobody came')."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Donations (optional Venmo tip QR shown on start/stop/shutdown)
# ---------------------------------------------------------------------------
variable "venmo_tip_url" {
  description = <<-EOT
    Clickable Venmo link for the tip prompt, e.g. "https://venmo.com/u/your-handle".
    When set, a tip embed with your QR image (assets/venmo-qr.png) is shown on /start,
    /stop, and the idle auto-shutdown. Leave empty to disable the tip feature entirely.
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Observability / abuse limits
# ---------------------------------------------------------------------------
variable "log_retention_days" {
  description = <<-EOT
    CloudWatch retention for the Lambda and API Gateway log groups. Bounded on
    purpose: these logs record source IPs and command activity, and keeping them
    forever is data you have to protect for no operational benefit.
  EOT
  type        = number
  default     = 30
}

variable "lambda_reserved_concurrency" {
  description = <<-EOT
    Concurrency ceiling for the bot Lambda. The interactions endpoint is public,
    so this caps what a request flood can cost even though each forged request is
    rejected. A handful of players never needs more than a couple of concurrent
    executions.
  EOT
  type        = number
  default     = 5
}

variable "api_throttle_rate" {
  description = "Steady-state request/sec ceiling on the interactions endpoint."
  type        = number
  default     = 10
}

variable "api_throttle_burst" {
  description = "Burst request ceiling on the interactions endpoint."
  type        = number
  default     = 20
}
