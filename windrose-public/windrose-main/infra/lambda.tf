# ---------------------------------------------------------------------------
# Lambda deployment package.
# Build it first with scripts/build_lambda.sh (installs PyNaCl for the Lambda
# runtime + copies handler.py into bot/build/package/). Terraform zips that dir.
# ---------------------------------------------------------------------------
data "archive_file" "bot" {
  type        = "zip"
  source_dir  = "${path.module}/../bot/build/package"
  output_path = "${path.module}/../bot/build/windrose-bot.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-bot"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_ec2" {
  # Start/Stop scoped to just this one instance.
  statement {
    sid       = "StartStop"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.windrose.id}"]
  }
  # Describe cannot be resource-scoped.
  statement {
    sid       = "Describe"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_ec2" {
  name   = "${local.name}-ec2"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_ec2.json
}

# Explicit log group so retention is bounded. Left implicit, Lambda creates one
# that never expires — an unbounded, indefinitely-retained record of who ran what.
resource "aws_cloudwatch_log_group" "bot" {
  #checkov:skip=CKV_AWS_338:30-day retention is a deliberate data-minimization choice; see docs/SECURITY.md.
  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption is sufficient for operational logs containing no secrets.
  name              = "/aws/lambda/${local.name}-bot"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "bot" {
  #checkov:skip=CKV_AWS_117:No VPC. The function only calls the public EC2 API; a VPC would add NAT cost and buy nothing.
  #checkov:skip=CKV_AWS_116:No DLQ. Discord retries interactions and the worst case is a dropped chat reply, not lost data.
  #checkov:skip=CKV_AWS_272:Code signing omitted — single-maintainer project, no signing profile infrastructure.
  #checkov:skip=CKV_AWS_173:Env vars hold no secrets (a public key, an instance ID, and two public URLs), so the default AWS-managed key is sufficient.
  #checkov:skip=CKV_AWS_50:X-Ray tracing omitted — three code paths, CloudWatch logs are enough to debug them.
  function_name    = "${local.name}-bot"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.bot.output_path
  source_code_hash = data.archive_file.bot.output_base64sha256
  timeout          = 10
  memory_size      = 128

  # Cap blast radius. The interactions endpoint is public by necessity; signature
  # verification rejects forged requests, but rejecting them still costs an
  # invocation. This bounds a flood to a predictable ceiling instead of scaling
  # the bill to whatever an attacker feels like spending.
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  depends_on = [aws_cloudwatch_log_group.bot]

  environment {
    variables = {
      DISCORD_PUBLIC_KEY = var.discord_public_key
      INSTANCE_ID        = aws_instance.windrose.id
      # Venmo tip prompt (empty = feature off; handler.py guards on empty).
      DONATE_VENMO_URL = var.venmo_tip_url
      DONATE_QR_URL    = local.donate_qr_url
    }
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bot.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.bot.execution_arn}/*/*"
}
