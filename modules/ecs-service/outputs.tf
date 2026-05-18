output "service_arn" {
  description = "ECS service ARN. Used by IAM policies and the console to deep-link into the AWS console."
  value       = aws_ecs_service.this.id
}

output "service_name" {
  description = "ECS service name (matches var.service_name)."
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "Active task definition ARN. Revisions accumulate over time; this is always the latest."
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "CloudWatch Logs group for this service. Consumed by observability dashboards and alarms in the application root."
  value       = aws_cloudwatch_log_group.this.name
}

output "task_role_arn" {
  description = "Task role ARN. Application roots can attach additional inline policies via aws_iam_role_policy referencing task_role_name."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Task role name. Use with aws_iam_role_policy.role = <name> to attach extra inline statements."
  value       = aws_iam_role.task.name
}
