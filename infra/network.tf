resource "aws_security_group" "windrose" {
  name        = "${local.name}-sg"
  description = "Windrose dedicated server. Egress all; RDP locked to admin; game port optional."
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${local.name}-sg" }
}

# RDP for first-time setup — only when an admin CIDR is provided.
resource "aws_security_group_rule" "rdp" {
  count             = var.allowed_rdp_cidr != "" ? 1 : 0
  type              = "ingress"
  security_group_id = aws_security_group.windrose.id
  protocol          = "tcp"
  from_port         = 3389
  to_port           = 3389
  cidr_blocks       = [var.allowed_rdp_cidr]
  description       = "RDP for setup (admin IP only)"
}

# Direct-Connection game port (TCP + UDP) — only when open_game_port = true.
# Not needed for the default NAT punch-through + invite-code mode.
resource "aws_security_group_rule" "game_tcp" {
  count             = var.open_game_port ? 1 : 0
  type              = "ingress"
  security_group_id = aws_security_group.windrose.id
  protocol          = "tcp"
  from_port         = var.game_port
  to_port           = var.game_port
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Windrose direct-connection (TCP)"
}

resource "aws_security_group_rule" "game_udp" {
  count             = var.open_game_port ? 1 : 0
  type              = "ingress"
  security_group_id = aws_security_group.windrose.id
  protocol          = "udp"
  from_port         = var.game_port
  to_port           = var.game_port
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Windrose direct-connection (UDP)"
}

resource "aws_security_group_rule" "egress_all" {
  #checkov:skip=CKV_AWS_382:The instance needs Steam CDN, Windows Update, SSM endpoints and Discord. Enumerating and maintaining those prefix lists is not worth it for a game server. See docs/SECURITY.md.
  type              = "egress"
  security_group_id = aws_security_group.windrose.id
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All outbound (SteamCMD, NAT punch-through, SSM, Discord webhook)"
}
