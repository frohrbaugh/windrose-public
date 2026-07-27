# Discord secrets/config the instance and tooling read at runtime.
# SecureString for the real secrets (webhook + bot token); plain String for IDs.

resource "aws_ssm_parameter" "webhook_url" {
  #checkov:skip=CKV_AWS_337:SecureString under the AWS-managed SSM key. A CMK would add key-policy control and rotation visibility for ~$1/mo; deliberate omission at this scale. See docs/SECURITY.md.
  name        = "/windrose/discord/webhook_url"
  description = "Discord incoming webhook the server posts online/offline messages to."
  type        = "SecureString"
  value       = var.discord_webhook_url
}

resource "aws_ssm_parameter" "bot_token" {
  #checkov:skip=CKV_AWS_337:Same as webhook_url — AWS-managed key, documented in docs/SECURITY.md.
  name        = "/windrose/discord/bot_token"
  description = "Discord bot token (used to register slash commands)."
  type        = "SecureString"
  value       = var.discord_bot_token
}

resource "aws_ssm_parameter" "application_id" {
  #checkov:skip=CKV2_AWS_34:Not a secret. A Discord application ID is published in every invite link.
  name  = "/windrose/discord/application_id"
  type  = "String"
  value = var.discord_application_id
}

resource "aws_ssm_parameter" "guild_id" {
  #checkov:skip=CKV2_AWS_34:Not a secret. A guild ID is visible to every member of the server.
  name  = "/windrose/discord/guild_id"
  type  = "String"
  value = var.discord_guild_id
}

# Idle-reaper tuning, read by idle-reaper.ps1 on the instance.
resource "aws_ssm_parameter" "idle_grace_minutes" {
  #checkov:skip=CKV2_AWS_34:A timeout in minutes. Encrypting it would only add a KMS call to every reaper run.
  name  = "/windrose/reaper/idle_grace_minutes"
  type  = "String"
  value = tostring(var.idle_grace_minutes)
}

resource "aws_ssm_parameter" "empty_on_boot_grace_minutes" {
  #checkov:skip=CKV2_AWS_34:A timeout in minutes; see idle_grace_minutes.
  name  = "/windrose/reaper/empty_on_boot_grace_minutes"
  type  = "String"
  value = tostring(var.empty_on_boot_grace_minutes)
}

# Venmo tip prompt, read by idle-reaper.ps1 (and the Lambda via env vars).
# Only created when the tip feature is enabled (SSM String values can't be empty).
resource "aws_ssm_parameter" "donate_venmo_url" {
  #checkov:skip=CKV2_AWS_34:A public profile URL that is deliberately shown to every player in the channel.
  count = var.venmo_tip_url != "" ? 1 : 0
  name  = "/windrose/donate/venmo_url"
  type  = "String"
  value = var.venmo_tip_url
}

resource "aws_ssm_parameter" "donate_qr_image_url" {
  #checkov:skip=CKV2_AWS_34:A public S3 object URL by design — Discord fetches it anonymously.
  count = var.venmo_tip_url != "" ? 1 : 0
  name  = "/windrose/donate/qr_image_url"
  type  = "String"
  value = local.donate_qr_url
}
