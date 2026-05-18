output "cluster_id" {
  description = "ECS cluster ID (same as ARN in the AWS provider; use cluster_arn for clarity in IAM policies)."
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "ECS cluster name. Used by aws_ecs_service.cluster, capacity-provider associations, and aws_ecs_capacity_provider lookups."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN. Used by application roots to grant ecs:DescribeClusters and friends."
  value       = aws_ecs_cluster.this.arn
}
