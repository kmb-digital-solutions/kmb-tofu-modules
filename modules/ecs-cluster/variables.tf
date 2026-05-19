variable "customer_slug" {
  description = "Customer slug used for naming and tagging. Lowercase alphanumeric and hyphens only."
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

variable "application_name" {
  description = <<-EOT
    Optional logical application slug (e.g., "spire", "traincover"). When
    non-empty, the cluster is named `<customer_slug>-<environment>-<application_name>`
    so multiple applications can coexist in the same customer+environment
    without colliding on cluster names.

    Default empty preserves the legacy `<customer_slug>-<environment>`
    prefix. `cluster_name_override` always wins over both.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.application_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.application_name))
    error_message = "application_name must be empty or 3-32 chars lowercase alphanumeric/hyphens, not starting or ending with a hyphen."
  }
}

variable "cluster_name_override" {
  description = "Optional explicit ECS cluster name. When null (default), the cluster is named '<customer_slug>-<environment>'."
  type        = string
  default     = null

  validation {
    condition     = var.cluster_name_override == null || can(regex("^[a-zA-Z0-9_-]{1,255}$", var.cluster_name_override))
    error_message = "cluster_name_override must match ECS cluster naming rules: 1-255 chars of letters, numbers, underscores, or hyphens."
  }
}

variable "enable_container_insights" {
  description = "When true, enable CloudWatch Container Insights on the cluster. Adds per-task CPU/memory/network metrics at additional CloudWatch cost."
  type        = bool
  default     = true
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the module emits safe-but-immortal settings. When false
    (non-prod), it emits cycle-friendly settings so N-cycle tests can
    apply/destroy repeatedly without manual cleanup. ECS clusters destroy
    cleanly when no services reference them, so this variable currently only
    influences tags; it is accepted for cross-module consistency.
  EOT
  type        = bool
  default     = false
}
