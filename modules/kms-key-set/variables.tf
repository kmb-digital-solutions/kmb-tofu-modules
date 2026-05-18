variable "customer_slug" {
  description = "Customer slug used in alias names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.customer_slug))
    error_message = "customer_slug must be 3-40 chars, lowercase alphanumeric and hyphens, not start or end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, staging, prod."
  type        = string

  validation {
    condition     = can(regex("^(dev|staging|prod)$", var.environment))
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "purposes" {
  description = <<-EOT
    Logical purposes for which to create CMK + alias pairs. Each becomes a
    CMK with alias `alias/<customer_slug>-<environment>-<purpose>`.
    Example: ["rds", "s3", "logs", "bedrock", "secrets"].
  EOT
  type        = list(string)

  validation {
    condition     = length(var.purposes) > 0
    error_message = "purposes must contain at least one entry."
  }

  validation {
    condition     = length(var.purposes) == length(toset(var.purposes))
    error_message = "purposes must not contain duplicates."
  }

  validation {
    condition     = alltrue([for p in var.purposes : can(regex("^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$", p))])
    error_message = "Each purpose must be 2-32 chars, lowercase alphanumeric and hyphens."
  }
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), keys use the 30-day deletion window. When false
    (non-prod), keys use the 7-day minimum so N-cycle tests can recreate
    keys without manual cleanup. The alias is a separate resource (see
    docs/module-development.md) and rebinds across cycles regardless.
  EOT
  type        = bool
  default     = false
}

variable "enable_multi_region" {
  description = <<-EOT
    When true, create each primary key as a multi-region key and replicate
    it into the configured replica region via the aws.replica provider
    alias. Intended for HIPAA-tier customers with us-west-2 DR.
  EOT
  type        = bool
  default     = false
}

variable "additional_policy_statements_by_purpose" {
  description = <<-EOT
    Optional per-purpose extension of the CMK key policy. Map of purpose
    name -> list of IAM policy statement objects, each merged into the key
    policy in addition to the default root-account-full-access statement.

    Use this when a specific purpose key must be usable by an AWS service
    principal (e.g., CloudWatch Logs needs `logs.<region>.amazonaws.com`
    on the "logs" key, or KMS-encrypted SNS needs `sns.amazonaws.com`).
    Service-principal grants cannot be added via aws_kms_grant for all
    services, so a key policy entry is the canonical mechanism.

    Each statement is a plain object that becomes an element of the
    policy's `Statement` array. Example:

      additional_policy_statements_by_purpose = {
        logs = [
          {
            Sid       = "CloudWatchLogsService"
            Effect    = "Allow"
            Principal = { Service = "logs.us-east-1.amazonaws.com" }
            Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
            Resource  = "*"
            Condition = {
              ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:us-east-1:*:log-group:*" }
            }
          }
        ]
      }
  EOT
  type        = map(list(any))
  default     = {}
}
