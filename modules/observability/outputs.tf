output "log_group_names" {
  description = "Map of input log group name to fully-qualified CloudWatch log group name."
  value = {
    for name, lg in aws_cloudwatch_log_group.this : name => lg.name
  }
}

output "log_group_arns" {
  description = "Map of input log group name to log group ARN."
  value = {
    for name, lg in aws_cloudwatch_log_group.this : name => lg.arn
  }
}

output "alarm_arns" {
  description = "Map of alarm name to alarm ARN."
  value = {
    for name, a in aws_cloudwatch_metric_alarm.this : name => a.arn
  }
}

output "sns_topic_arn" {
  description = "ARN of the module-managed SNS topic when enable_sns_topic = true; null otherwise."
  value       = local.module_topic_arn
}
