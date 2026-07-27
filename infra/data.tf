data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Latest Windows Server 2022 base AMI (used when custom_ami_id is empty).
data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

# Default VPC + subnets — keeps the footprint minimal (no custom networking).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  ami_id    = var.custom_ami_id != "" ? var.custom_ami_id : data.aws_ssm_parameter.windows_ami.value
  subnet_id = element(tolist(data.aws_subnets.default.ids), 0)
  name      = "windrose"

  # Public URL of the Venmo tip QR image (empty when the tip feature is off).
  # one() safely yields null for the count=0 case; the ternary avoids using it.
  donate_qr_url = var.venmo_tip_url != "" ? "https://${one(aws_s3_bucket.assets[*].bucket)}.s3.${data.aws_region.current.name}.amazonaws.com/${local.qr_key}" : ""
}
