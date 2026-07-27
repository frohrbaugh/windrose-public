output "instance_id" {
  description = "EC2 instance ID of the Windrose server."
  value       = aws_instance.windrose.id
}

output "interactions_endpoint_url" {
  description = "Paste this into the Discord app's 'Interactions Endpoint URL' field."
  value       = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/interactions"
}

output "lambda_function_name" {
  description = "Name of the bot Lambda (for logs/debugging)."
  value       = aws_lambda_function.bot.function_name
}

output "security_group_id" {
  value = aws_security_group.windrose.id
}

output "instance_public_ip" {
  description = "Current public IP (for RDP). Changes on each stop/start — no Elastic IP by design. Null when stopped."
  value       = aws_instance.windrose.public_ip
}

output "region" {
  value = var.aws_region
}
