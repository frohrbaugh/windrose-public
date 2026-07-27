"""Windrose Discord bot — AWS Lambda behind an API Gateway HTTP API.

Discord posts slash-command interactions here. We:
  1. Verify the Ed25519 signature (required by Discord).
  2. Answer the PING handshake.
  3. Route /start, /status, /stop to EC2 start/stop/describe and reply
     immediately (Discord requires a response within 3 seconds).

The "server is online + invite code" and "shutting down" messages are NOT sent
from here — the instance itself posts those to a Discord webhook once it has
actually booted / decided to stop. That keeps this Lambda fast and stateless.
"""

import base64
import json
import logging
import os

import boto3
from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

log = logging.getLogger()
log.setLevel(logging.INFO)

PUBLIC_KEY = os.environ["DISCORD_PUBLIC_KEY"]
INSTANCE_ID = os.environ["INSTANCE_ID"]

ec2 = boto3.client("ec2")

# Discord interaction / response type constants.
PING = 1
APPLICATION_COMMAND = 2
PONG = 1
CHANNEL_MESSAGE_WITH_SOURCE = 4
EPHEMERAL = 64


def _verify(signature: str, timestamp: str, body: str) -> bool:
    """Return True if the request genuinely came from Discord."""
    try:
        VerifyKey(bytes.fromhex(PUBLIC_KEY)).verify(
            (timestamp + body).encode(), bytes.fromhex(signature)
        )
        return True
    except (BadSignatureError, ValueError, TypeError):
        return False


def _reply(content: str, ephemeral: bool = False, embeds: list | None = None) -> dict:
    data = {"content": content}
    if ephemeral:
        data["flags"] = EPHEMERAL
    if embeds:
        data["embeds"] = embeds
    return _http(200, {"type": CHANNEL_MESSAGE_WITH_SOURCE, "data": data})


def _tip_embed() -> dict | None:
    """Venmo tip embed, or None when the tip feature isn't configured."""
    venmo = os.environ.get("DONATE_VENMO_URL")
    if not venmo:
        return None
    embed = {
        "title": "Enjoyed the server? Tip the host 🙏",
        "description": (
            "This box runs on my dime — if you had fun, a tip keeps it alive.\n"
            f"**[Open Venmo]({venmo})**"
        ),
        "color": 0x3D95CE,  # Venmo blue
    }
    qr = os.environ.get("DONATE_QR_URL")
    if qr:
        embed["image"] = {"url": qr}
    return embed


def _tip_embeds() -> list | None:
    embed = _tip_embed()
    return [embed] if embed else None


def _http(status: int, obj: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(obj),
    }


def _instance_state() -> str:
    """Current instance state name, e.g. 'running', 'stopped', 'pending'."""
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return resp["Reservations"][0]["Instances"][0]["State"]["Name"]


def _cmd_start() -> dict:
    tip = _tip_embeds()
    state = _instance_state()
    if state == "running":
        return _reply("🟢 The Windrose server is already up. Check the invite code above.", embeds=tip)
    if state in ("pending",):
        return _reply("⏳ Already starting — the invite code will post here shortly.", embeds=tip)
    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    return _reply(
        "⏳ Starting the Windrose server… the invite code will be posted here in ~2–3 minutes.",
        embeds=tip,
    )


def _cmd_status() -> dict:
    state = _instance_state()
    emoji = {"running": "🟢", "stopped": "🔴", "pending": "⏳", "stopping": "🟠"}.get(state, "⚪")
    note = ""
    if state == "running":
        note = " (invite code is in the channel above; players connect via the code)"
    return _reply(f"{emoji} Windrose server is **{state}**{note}.", ephemeral=True)


def _cmd_stop() -> dict:
    state = _instance_state()
    if state in ("stopped", "stopping"):
        return _reply(f"🔴 Server is already **{state}**.")
    ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    return _reply("🔴 Stopping the Windrose server now.", embeds=_tip_embeds())


COMMANDS = {"start": _cmd_start, "status": _cmd_status, "stop": _cmd_stop}


def lambda_handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()

    signature = headers.get("x-signature-ed25519", "")
    timestamp = headers.get("x-signature-timestamp", "")
    if not _verify(signature, timestamp, body):
        return _http(401, {"error": "invalid request signature"})

    interaction = json.loads(body)

    if interaction.get("type") == PING:
        return _http(200, {"type": PONG})

    if interaction.get("type") == APPLICATION_COMMAND:
        name = (interaction.get("data") or {}).get("name", "")
        handler = COMMANDS.get(name)
        if handler:
            try:
                return handler()
            except Exception:  # noqa: BLE001 — any AWS failure becomes one generic reply
                # Log the detail to CloudWatch, where only the account owner can
                # read it. Do NOT echo it into Discord: boto3 exceptions carry
                # instance IDs, role ARNs, and the account ID, and this channel
                # is readable by everyone in the guild.
                log.exception("command %s failed", name)
                return _reply(
                    "⚠️ Something went wrong talking to AWS. "
                    "Try again in a moment — the details are in the server logs.",
                    ephemeral=True,
                )

    return _reply("Unknown command.", ephemeral=True)
