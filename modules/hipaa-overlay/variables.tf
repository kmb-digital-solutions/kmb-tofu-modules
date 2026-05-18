###############################################################################
# Module: hipaa-overlay — variables
#
# This module is the documented exception to the N-cycle rule: it deploys
# resources whose retention cannot be cleaned (AWS Backup Vault Lock
# COMPLIANCE, S3 Object Lock COMPLIANCE). It REFUSES to deploy unless
# destroy_protection = true. Application roots compose it conditionally:
#
#   module "hipaa" {
#     count  = var.hipaa_enabled && var.destroy_protection ? 1 : 0
#     source = "git::https://.../modules/hipaa-overlay?ref=hipaa-overlay/vX.Y.Z"
#     ...
#   }
###############################################################################

variable "customer_slug" {
  description = "Customer slug used for naming and tagging. Lowercase alphanumeric and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.customer_slug))
    error_message = "customer_slug must be 3-40 chars, lowercase alphanumeric and hyphens, not start or end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment. The HIPAA overlay is prod-only — composing it in any other environment is a configuration error."
  type        = string

  validation {
    condition     = can(regex("^prod$", var.environment))
    error_message = "environment must be 'prod'. The hipaa-overlay module is prod-only."
  }
}

variable "aws_account_id" {
  description = "The 12-digit AWS account ID where the overlay is deployed. Used for ARN composition (e.g., conformance pack delivery)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit numeric string."
  }
}

variable "security_account_id" {
  description = <<-EOT
    The 12-digit AWS account ID of the central security account that receives
    CloudTrail logs, GuardDuty findings, Macie findings, and Security Hub
    aggregation. Must be in the same AWS Organization as aws_account_id.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.security_account_id))
    error_message = "security_account_id must be a 12-digit numeric string."
  }
}

variable "destroy_protection" {
  description = <<-EOT
    Refusal switch. This module deploys irreversible retention (Backup Vault
    Lock COMPLIANCE, optionally S3 Object Lock COMPLIANCE). It REFUSES to
    deploy unless this is true. Application roots gate composition on this
    AND on hipaa_enabled.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = var.destroy_protection == true
    error_message = "hipaa-overlay deploys resources with retention that cannot be cleaned; set destroy_protection = true or stop composing this module."
  }
}

variable "regions" {
  description = <<-EOT
    AWS regions to enable regional services in. AWS Config and GuardDuty are
    regional; CloudTrail is multi-region by design and ignores this list.
    Defaults to a single region in us-east-1.
  EOT
  type        = list(string)
  default     = ["us-east-1"]

  validation {
    condition     = length(var.regions) >= 1
    error_message = "regions must contain at least one entry."
  }

  validation {
    condition     = alltrue([for r in var.regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", r))])
    error_message = "Each region must be a valid AWS region code (e.g., us-east-1)."
  }
}

variable "backup_kms_key_arn" {
  description = "ARN of the customer-managed KMS key that encrypts the Backup vault. Sourced from the kms-key-set module's 'backup' purpose."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", var.backup_kms_key_arn))
    error_message = "backup_kms_key_arn must be a valid KMS key ARN."
  }
}

variable "s3_logs_bucket_arn" {
  description = "Optional ARN of a centralized S3 logging bucket. When null, AWS Config delivers to the same bucket as CloudTrail."
  type        = string
  default     = null

  validation {
    condition     = var.s3_logs_bucket_arn == null || can(regex("^arn:aws:s3:::[a-z0-9.-]+$", var.s3_logs_bucket_arn))
    error_message = "s3_logs_bucket_arn must be null or a valid S3 bucket ARN."
  }
}

variable "cloudtrail_s3_bucket" {
  description = "Name of the S3 bucket that receives CloudTrail logs. The bucket lives in the security account and must already exist with a bucket policy that allows this account to write."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.cloudtrail_s3_bucket))
    error_message = "cloudtrail_s3_bucket must be a valid S3 bucket name (3-63 chars, lowercase alphanumeric, dots, hyphens)."
  }
}

variable "s3_data_event_buckets" {
  description = "S3 bucket ARNs whose object-level API calls (GetObject, PutObject, DeleteObject) should be captured as CloudTrail data events. Use for PHI-bearing buckets."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for b in var.s3_data_event_buckets : can(regex("^arn:aws:s3:::[a-z0-9.-]+$", b))])
    error_message = "Each s3_data_event_buckets entry must be a valid S3 bucket ARN."
  }
}

variable "enable_guardduty" {
  description = "When true, enable GuardDuty in this account and invite the security account as the master."
  type        = bool
  default     = true
}

variable "guardduty_master_account_id" {
  description = "Account ID of the GuardDuty delegated administrator / master. Defaults to security_account_id when null."
  type        = string
  default     = null

  validation {
    condition     = var.guardduty_master_account_id == null || can(regex("^[0-9]{12}$", var.guardduty_master_account_id))
    error_message = "guardduty_master_account_id must be null or a 12-digit numeric string."
  }
}

variable "enable_macie" {
  description = "When true, enable Macie for PHI/PII discovery in S3."
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = "When true, enable Security Hub and subscribe to AWS Foundational Security Best Practices + CIS standards."
  type        = bool
  default     = true
}

variable "enable_inspector" {
  description = "When true, enable Amazon Inspector for ECR + EC2 + Lambda resource scanning."
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "When true, enable AWS Config with the AWS-managed Operational-Best-Practices-for-HIPAA-Security conformance pack."
  type        = bool
  default     = true
}

variable "backup_plan_rules" {
  description = <<-EOT
    Backup plan rules. Each rule defines a schedule, target vault, lifecycle,
    and optional cold-storage transition / cross-region copy. The module
    creates the compliance vault automatically; rules reference it by name.

    Example:
      [
        {
          rule_name                         = "daily"
          schedule_expression               = "cron(0 5 ? * * *)"
          start_window_minutes              = 60
          completion_window_minutes         = 360
          target_vault_name                 = "<customer>-prod-compliance-vault"
          delete_after_days                 = 2555  # 7 years
          lifecycle_cold_storage_after_days = 90
        }
      ]
  EOT
  type = list(object({
    rule_name                         = string
    schedule_expression               = string
    start_window_minutes              = number
    completion_window_minutes         = number
    target_vault_name                 = string
    delete_after_days                 = number
    lifecycle_cold_storage_after_days = optional(number)
    copy_to_destination_vault_arn     = optional(string)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.backup_plan_rules : r.delete_after_days >= 1])
    error_message = "Each backup_plan_rules.delete_after_days must be >= 1."
  }

  validation {
    condition     = alltrue([for r in var.backup_plan_rules : r.start_window_minutes >= 60])
    error_message = "Each backup_plan_rules.start_window_minutes must be >= 60 (AWS minimum)."
  }

  validation {
    condition     = alltrue([for r in var.backup_plan_rules : r.completion_window_minutes >= r.start_window_minutes])
    error_message = "Each backup_plan_rules.completion_window_minutes must be >= start_window_minutes."
  }

  validation {
    condition     = alltrue([for r in var.backup_plan_rules : can(regex("^cron\\(.+\\)$", r.schedule_expression))])
    error_message = "Each backup_plan_rules.schedule_expression must be a cron() expression (e.g., cron(0 5 ? * * *))."
  }
}
