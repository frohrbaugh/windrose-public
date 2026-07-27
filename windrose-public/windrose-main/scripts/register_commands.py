#!/usr/bin/env python3
"""Register the /start, /status, /stop guild slash commands with Discord.

Run once (and again whenever the command list changes). Guild commands appear
instantly, unlike global commands which can take up to an hour.

Config is read from SSM Parameter Store (the values Terraform stored) via the
local `aws` CLI, so there are no Python dependencies. Override any value with a
flag if you'd rather not read from SSM.

    python3 scripts/register_commands.py                 # read all from SSM
    python3 scripts/register_commands.py --profile my-sso-profile --region us-east-1
    python3 scripts/register_commands.py --app-id ... --guild-id ...

Prefer letting the token come from SSM. Passing --token puts a live Discord bot
token in your shell history and in the process list for every user on the box.
"""
import argparse
import json
import subprocess  # nosec B404: used only with fixed argv lists, never shell=True
import sys
import urllib.error
import urllib.request

COMMANDS = [
    {"name": "start", "type": 1, "description": "Start the Windrose server (posts the invite code here when ready)"},
    {"name": "status", "type": 1, "description": "Check whether the Windrose server is up"},
    {"name": "stop", "type": 1, "description": "Stop the Windrose server now"},
]


def ssm(name: str, profile: str | None, region: str, decrypt: bool) -> str:
    cmd = ["aws", "ssm", "get-parameter", "--name", name,
           "--query", "Parameter.Value", "--output", "text",
           "--region", region]
    if profile:
        cmd += ["--profile", profile]
    if decrypt:
        cmd.append("--with-decryption")
    try:
        # nosec B603: fixed argv list, no shell, and every element is either a
        # literal or a value this script itself constructed.
        return subprocess.check_output(cmd, text=True).strip()  # nosec B603
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        sys.exit(f"Failed to read SSM parameter {name}: {exc}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile", default=None,
                    help="AWS profile (default: the standard credential chain)")
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument("--token", help="Discord bot token. Prefer SSM; see the note above.")
    ap.add_argument("--app-id", help="Discord application ID (default: from SSM)")
    ap.add_argument("--guild-id", help="Discord guild ID (default: from SSM)")
    args = ap.parse_args()

    token = args.token or ssm("/windrose/discord/bot_token", args.profile, args.region, True)
    app_id = args.app_id or ssm("/windrose/discord/application_id", args.profile, args.region, False)
    guild_id = args.guild_id or ssm("/windrose/discord/guild_id", args.profile, args.region, False)

    url = f"https://discord.com/api/v10/applications/{app_id}/guilds/{guild_id}/commands"
    req = urllib.request.Request(
        url,
        data=json.dumps(COMMANDS).encode(),
        method="PUT",
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            # Discord requires a descriptive User-Agent; the urllib default is
            # blocked by Cloudflare (403, error 1010).
            "User-Agent": "DiscordBot (https://github.com/frohrbaugh/windrose, 1.0)",
        },
    )
    try:
        # nosec B310: the URL is an f-string over a hardcoded https://discord.com
        # base, so no caller-controlled scheme (file:, ftp:) can be substituted.
        with urllib.request.urlopen(req) as resp:  # nosec B310
            registered = json.load(resp)
        print(f"✅ Registered {len(registered)} commands in guild {guild_id}:")
        for c in registered:
            print(f"   /{c['name']} — {c['description']}")
    except urllib.error.HTTPError as exc:
        sys.exit(f"❌ Discord API error {exc.code}: {exc.read().decode()}")


if __name__ == "__main__":
    main()
