# Public HTTPS endpoint Discord posts interactions to.
#
# This route is intentionally unauthenticated at the API Gateway layer: Discord
# signs every interaction with Ed25519 and will not send an IAM SigV4 or JWT
# credential. Authentication happens in the Lambda, which verifies the signature
# against the app's public key BEFORE parsing the body and rejects anything that
# fails with a 401. Access logging and throttling below cover what the missing
# gateway-level authorizer would otherwise give us.
resource "aws_apigatewayv2_api" "bot" {
  name          = "${local.name}-bot"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "bot" {
  api_id                 = aws_apigatewayv2_api.bot.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.bot.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "interactions" {
  #checkov:skip=CKV_AWS_309:Discord cannot present IAM/JWT credentials. Ed25519 signature verification in handler.py is the authenticator; see the comment above.
  api_id    = aws_apigatewayv2_api.bot.id
  route_key = "POST /interactions"
  target    = "integrations/${aws_apigatewayv2_integration.bot.id}"
}

# Audit trail for a public endpoint. Without this there is no record of who hit
# the interactions URL, which makes it impossible to tell a Discord outage apart
# from someone probing the endpoint.
resource "aws_cloudwatch_log_group" "apigw" {
  #checkov:skip=CKV_AWS_338:Retention is intentionally 30 days, not 365. These logs contain source IPs; keeping them a year is data to defend with no operational benefit for a game server.
  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption. Bodies are excluded from the log format, so nothing sensitive is stored to warrant a CMK.
  name              = "/aws/apigateway/${local.name}-bot"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.bot.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    # Deliberately omits any request body — Discord interaction payloads carry
    # usernames and command arguments, and there is no reason to durably store
    # them to operate a game server.
    format = jsonencode({
      requestId      = "$context.requestId"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationErr = "$context.integrationErrorMessage"
      integrationLat = "$context.integrationLatency"
      sourceIp       = "$context.identity.sourceIp"
    })
  }

  default_route_settings {
    throttling_burst_limit = var.api_throttle_burst
    throttling_rate_limit  = var.api_throttle_rate
  }
}
