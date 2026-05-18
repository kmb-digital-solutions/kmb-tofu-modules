variable "customer_slug" {
  description = "Customer slug used for tagging only (the repository_name is the full path under the customer/env namespace). Lowercase alphanumeric and hyphens."
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

variable "repository_name" {
  description = <<-EOT
    Full ECR repository name (path under the registry). Lowercase, may
    contain slashes for namespacing, e.g. "<customer_slug>/<environment>/api".
    Composition is the caller's choice — this module never builds the name
    from customer_slug + environment because callers may want flat or nested
    layouts.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_/-]{0,254}$", var.repository_name))
    error_message = "repository_name must be 1-255 lowercase chars; letters, numbers, underscores, hyphens, and slashes allowed, must not start with a separator."
  }
}

variable "image_tag_mutability" {
  description = "ECR tag mutability. IMMUTABLE blocks re-pushing the same tag, which is the supply-chain-safe default."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be either IMMUTABLE or MUTABLE."
  }
}

variable "scan_on_push" {
  description = "Run ECR basic image scan on every push. Free; surfaces CVEs visible in the AWS console."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN for repository encryption. When null, the repository uses ECR's AES-256 default."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]+:key/[a-f0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a valid KMS key ARN or null."
  }
}

variable "untagged_image_retention_count" {
  description = "Number of untagged images to retain. Older untagged images are expired by lifecycle policy. Must be >= 1."
  type        = number
  default     = 30

  validation {
    condition     = var.untagged_image_retention_count >= 1 && var.untagged_image_retention_count <= 1000
    error_message = "untagged_image_retention_count must be between 1 and 1000."
  }
}

variable "tagged_image_retention_count" {
  description = "Number of tagged images to retain. Older tagged images are expired by lifecycle policy. Must be >= 1."
  type        = number
  default     = 100

  validation {
    condition     = var.tagged_image_retention_count >= 1 && var.tagged_image_retention_count <= 10000
    error_message = "tagged_image_retention_count must be between 1 and 10000."
  }
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the module emits safe-but-immortal settings:
    force_delete = false, so destroying a repository containing images
    fails loudly. When false (non-prod), force_delete = true so N-cycle
    tests can destroy the repo regardless of image contents.
  EOT
  type        = bool
  default     = false
}
