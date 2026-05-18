output "endpoint" {
  description = "RDS endpoint hostname (no port). Use with port output below."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port. Always 5432 for Postgres but exposed for clarity in app config."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name created on the instance."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master Postgres username. Application code should prefer IAM auth where possible."
  value       = aws_db_instance.this.username
}

output "master_password_secret_arn" {
  description = "Secrets Manager ARN holding {username, password, engine, host, port, dbname}. Callers grant their task role secretsmanager:GetSecretValue on this ARN."
  value       = aws_secretsmanager_secret.master.arn
}

output "security_group_id" {
  description = "DB security group ID. Callers may add their own ingress sources here if dynamic discovery is preferred over passing source_security_group_ids."
  value       = aws_security_group.this.id
}

output "instance_arn" {
  description = "RDS instance ARN. Used by IAM policies for IAM auth (rds-db:connect)."
  value       = aws_db_instance.this.arn
}

output "instance_id" {
  description = "RDS instance ID (the identifier)."
  value       = aws_db_instance.this.id
}
