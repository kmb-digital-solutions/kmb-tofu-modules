output "repository_url" {
  description = "ECR repository URL (registry/host/path). Consumed by ECS task definitions as `$${repository_url}:<tag>`."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN. Used by IAM policies that grant push/pull to specific repositories."
  value       = aws_ecr_repository.this.arn
}

output "repository_name" {
  description = "ECR repository name (path under the registry). Used by AWS CLI, repository policies, and cross-account replication rules."
  value       = aws_ecr_repository.this.name
}
