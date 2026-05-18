output "backup_vault_arn" {
  description = "ARN of the COMPLIANCE-locked Backup vault."
  value       = aws_backup_vault.compliance.arn
}

output "backup_vault_name" {
  description = "Name of the COMPLIANCE-locked Backup vault. Application roots reference this name when wiring aws_backup_selection."
  value       = aws_backup_vault.compliance.name
}

output "backup_plan_id" {
  description = "ID of the Backup plan. Null when no backup_plan_rules were supplied."
  value       = length(aws_backup_plan.this) > 0 ? aws_backup_plan.this[0].id : null
}

output "backup_plan_arn" {
  description = "ARN of the Backup plan. Null when no backup_plan_rules were supplied."
  value       = length(aws_backup_plan.this) > 0 ? aws_backup_plan.this[0].arn : null
}

output "backup_iam_role_arn" {
  description = "ARN of the IAM role used by AWS Backup. Application roots reference this when creating aws_backup_selection."
  value       = aws_iam_role.backup.arn
}

output "cloudtrail_arn" {
  description = "ARN of the CloudTrail organization trail."
  value       = aws_cloudtrail.this.arn
}

output "cloudtrail_name" {
  description = "Name of the CloudTrail organization trail."
  value       = aws_cloudtrail.this.name
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID. Null when enable_guardduty is false."
  value       = length(aws_guardduty_detector.this) > 0 ? aws_guardduty_detector.this[0].id : null
}

output "macie_account_id" {
  description = "Macie account-enablement resource ID. Null when enable_macie is false."
  value       = length(aws_macie2_account.this) > 0 ? aws_macie2_account.this[0].id : null
}

output "security_hub_account_id" {
  description = "Security Hub account-subscription resource ID. Null when enable_security_hub is false."
  value       = length(aws_securityhub_account.this) > 0 ? aws_securityhub_account.this[0].id : null
}

output "inspector_status" {
  description = "Indicator string for Inspector v2 status: 'enabled' or 'disabled'."
  value       = var.enable_inspector ? "enabled" : "disabled"
}

output "config_recorder_name" {
  description = "Name of the AWS Config configuration recorder. Null when enable_config is false."
  value       = length(aws_config_configuration_recorder.this) > 0 ? aws_config_configuration_recorder.this[0].name : null
}
