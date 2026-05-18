variable "customer_slug" {
  description = "Customer slug used in bucket name and tagging."
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

variable "purpose" {
  description = <<-EOT
    Bucket purpose embedded in the bucket name (e.g., "documents",
    "audit-archive", "static-assets"). Must satisfy S3 bucket naming rules
    after composition with customer_slug and environment.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.purpose))
    error_message = "purpose must be 3-32 chars, lowercase alphanumeric and hyphens, not start or end with a hyphen."
  }
}

variable "bucket_name_override" {
  description = <<-EOT
    Escape hatch when the generated bucket name "<customer_slug>-<environment>-<purpose>"
    collides with an existing global S3 bucket name. Leave null for the
    standard naming convention.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.bucket_name_override == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name_override))
    error_message = "bucket_name_override must be 3-63 chars, lowercase alphanumeric, hyphens, periods."
  }
}

variable "kms_key_arn" {
  description = "ARN of the KMS CMK used for SSE-KMS. Pass an output from modules/kms-key-set."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z-]+:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a valid KMS key ARN."
  }
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the bucket has force_destroy = false; tofu destroy
    fails if the bucket has any objects (intentional safety). When false
    (non-prod), force_destroy = true so N-cycle tests can recreate the
    bucket without manual emptying.
  EOT
  type        = bool
  default     = false
}

variable "enable_object_lock_compliance" {
  description = <<-EOT
    Enable S3 Object Lock in COMPLIANCE mode at bucket creation. Object
    Lock CANNOT be enabled after the bucket exists, and COMPLIANCE mode
    retention CANNOT be removed by anyone, including the root account, for
    the duration of the retention period. ONLY enable this from the
    hipaa-overlay module. Refused unless destroy_protection = true (the
    enforcing precondition lives on the bucket resource).
  EOT
  type        = bool
  default     = false
}

variable "lifecycle_rules" {
  description = <<-EOT
    Opt-in S3 lifecycle rules. Each rule must have a unique id and at
    least one of expiration, transition, or noncurrent_version_*.
    Example:
      [{
        id      = "expire-90d"
        enabled = true
        filter_prefix = ""
        expiration_days = 90
        transitions = []
        noncurrent_version_expiration_days = null
      }]
  EOT
  type = list(object({
    id                                 = string
    enabled                            = bool
    filter_prefix                      = optional(string, "")
    expiration_days                    = optional(number)
    abort_incomplete_multipart_days    = optional(number)
    noncurrent_version_expiration_days = optional(number)
    transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
  }))
  default = []

  validation {
    condition     = length(var.lifecycle_rules) == length(toset([for r in var.lifecycle_rules : r.id]))
    error_message = "lifecycle_rules must have unique ids."
  }
}

variable "cors_rules" {
  description = <<-EOT
    Opt-in CORS rules. Each rule maps to a single CORSRule on the bucket.
    allowed_origins MUST NOT contain "*" combined with allowed_headers
    "*" — the module does not enforce this beyond AWS's own validation.
  EOT
  type = list(object({
    allowed_headers = optional(list(string), [])
    allowed_methods = list(string)
    allowed_origins = list(string)
    expose_headers  = optional(list(string), [])
    max_age_seconds = optional(number, 3000)
  }))
  default = []
}
