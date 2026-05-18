output "pool_id" {
  description = "ID of the Cognito user pool."
  value       = aws_cognito_user_pool.this.id
}

output "pool_arn" {
  description = "ARN of the Cognito user pool."
  value       = aws_cognito_user_pool.this.arn
}

output "app_client_ids" {
  description = "Map of app client name to its client id."
  value = {
    for name, client in aws_cognito_user_pool_client.this : name => client.id
  }
}

output "app_client_secrets" {
  description = "Map of app client name to its client secret. Only populated for clients with generate_secret = true; clients without a secret are omitted from the map."
  value = {
    for name, client in aws_cognito_user_pool_client.this :
    name => client.client_secret
    if local.app_clients_by_name[name].generate_secret
  }
  sensitive = true
}

output "pool_domain" {
  description = "Cognito-prefix domain (<customer_slug>-<environment>) when advanced security is enabled; null otherwise."
  value       = var.enable_advanced_security ? aws_cognito_user_pool_domain.this[0].domain : null
}
