# ---------------------------------------------------------------------------
# Static asset hosting for the Venmo tip QR code.
#
# When var.venmo_tip_url is set, the host's Venmo "Venmo Me" QR image
# (assets/venmo-qr.png, supplied locally and gitignored) is uploaded to a small
# S3 bucket. Discord renders embed images by fetching the URL anonymously from
# its own servers, so the object has to be publicly readable — there is no way
# to hand Discord a presigned URL that stays valid for an arbitrarily old embed.
#
# The exposure is therefore deliberate but tightly bounded:
#   * the public grant names ONE object key, not the bucket or a /* prefix,
#   * ACLs remain fully blocked; the explicit policy is the only grant,
#   * versioning + TLS-only enforcement are on,
#   * leave venmo_tip_url empty and NONE of these resources are created.
#
# See docs/SECURITY.md ("Accepted risks") for the full write-up.
# ---------------------------------------------------------------------------

locals {
  qr_key = "venmo-qr.png"
}

resource "aws_s3_bucket" "assets" {
  #checkov:skip=CKV2_AWS_6:A public access block IS defined — see aws_s3_bucket_public_access_block.assets below. Checkov's graph check misses it because both resources are behind count.
  #checkov:skip=CKV_AWS_144:No cross-region replication. The sole object is a locally-held image that can be re-uploaded with one terraform apply.
  #checkov:skip=CKV_AWS_145:SSE-S3 rather than KMS. The object is deliberately world-readable, so encrypting it with a CMK protects nothing.
  #checkov:skip=CKV_AWS_18:Access logging omitted — one public, non-sensitive object; log storage would cost more than the asset is worth.
  #checkov:skip=CKV2_AWS_62:Event notifications are pointless for a single static object written once by Terraform.
  #checkov:skip=CKV2_AWS_61:No lifecycle rules needed — the bucket holds exactly one small object.
  count  = var.venmo_tip_url != "" ? 1 : 0
  bucket = "${local.name}-assets-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "assets" {
  count  = var.venmo_tip_url != "" ? 1 : 0
  bucket = aws_s3_bucket.assets[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  count  = var.venmo_tip_url != "" ? 1 : 0
  bucket = aws_s3_bucket.assets[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  #checkov:skip=CKV_AWS_54:Intentional. Discord fetches embed images anonymously, so the QR object must be public. The policy below is scoped to one key.
  #checkov:skip=CKV_AWS_56:Same as above — a bucket-level restriction would break the only grant this bucket exists to provide.
  count  = var.venmo_tip_url != "" ? 1 : 0
  bucket = aws_s3_bucket.assets[0].id

  # ACLs stay blocked in both directions; the scoped policy below is the only
  # path to the object. Policy-level public access is permitted by necessity.
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "assets_public_read" {
  count = var.venmo_tip_url != "" ? 1 : 0

  # Public read of the QR image ONLY — note the explicit key, not "/*".
  statement {
    sid       = "PublicReadQrObjectOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets[0].arn}/${local.qr_key}"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # Reject anything that arrives over plaintext HTTP.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.assets[0].arn,
      "${aws_s3_bucket.assets[0].arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  count      = var.venmo_tip_url != "" ? 1 : 0
  bucket     = aws_s3_bucket.assets[0].id
  policy     = data.aws_iam_policy_document.assets_public_read[0].json
  depends_on = [aws_s3_bucket_public_access_block.assets]
}

resource "aws_s3_object" "venmo_qr" {
  count        = var.venmo_tip_url != "" ? 1 : 0
  bucket       = aws_s3_bucket.assets[0].id
  key          = local.qr_key
  source       = "${path.module}/../assets/${local.qr_key}"
  content_type = "image/png"
  # fileexists guard: filemd5() on a literal path is evaluated eagerly (even when
  # count = 0), so it must not fail when the tip feature is off / image absent.
  etag = fileexists("${path.module}/../assets/${local.qr_key}") ? filemd5("${path.module}/../assets/${local.qr_key}") : null

  lifecycle {
    precondition {
      condition     = fileexists("${path.module}/../assets/${local.qr_key}")
      error_message = "venmo_tip_url is set but assets/venmo-qr.png is missing. The QR is gitignored on purpose — drop your own copy in assets/ (see assets/README.md), or clear venmo_tip_url to disable the tip feature."
    }
  }
}
