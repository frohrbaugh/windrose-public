# ---------------------------------------------------------------------------
# Instance IAM role: SSM management + read Discord webhook from Parameter Store.
# Self-stop is done by the OS (Stop-Computer) via shutdown_behavior = "stop",
# so NO ec2:StopInstances permission is needed here.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

# Session Manager / Fleet Manager remote access (no key pair / open RDP required).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance_ssm_read" {
  statement {
    sid       = "ReadWindroseParams"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/windrose/*"]
  }
  statement {
    sid       = "DecryptSecureStrings"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "instance_ssm_read" {
  name   = "${local.name}-ssm-read"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_ssm_read.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# The EC2 Windows instance.
# ---------------------------------------------------------------------------
resource "aws_instance" "windrose" {
  #checkov:skip=CKV_AWS_135:t3 instances are EBS-optimized by default; the attribute is a no-op here.
  #checkov:skip=CKV_AWS_126:Detailed (1-minute) monitoring bills per metric for a box that is powered off most of the month. Default 5-minute metrics are enough to watch a game server.
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.windrose.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null

  # Critical: /start powers the instance on; the reaper runs Stop-Computer to
  # power it off. "stop" (not "terminate") preserves the disk and its data.
  instance_initiated_shutdown_behavior = "stop"

  # Require IMDSv2. The instance profile can read Discord secrets from SSM, so a
  # server-side request forgery in anything running on this box must not be able
  # to reach 169.254.169.254 and lift those credentials. IMDSv2's PUT-token
  # handshake plus a hop limit of 1 blocks the classic SSRF and container-escape
  # metadata paths. install-windrose.ps1 already speaks IMDSv2; this enforces it.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    delete_on_termination = true
    encrypted             = true
  }

  # Base Windows AMI changes over time; ignore so a newer base AMI doesn't try
  # to replace a running, installed server. Pin custom_ami_id after AMI capture.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = local.name }
}
