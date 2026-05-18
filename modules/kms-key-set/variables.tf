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
