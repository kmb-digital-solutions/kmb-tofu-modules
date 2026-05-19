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
    Optional logical application slug. When non-empty, VPC, subnet, route
    table, IGW, NAT, and VPC-endpoint Name tags use the prefix
    `<customer_slug>-<environment>-<application_name>-...` so multiple
    applications in the same customer+environment don't share Name tags.

    Default empty preserves the legacy
    `<customer_slug>-<environment>-...` Name tags.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.application_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.application_name))
    error_message = "application_name must be empty or 3-32 chars lowercase alphanumeric/hyphens, not starting or ending with a hyphen."
  }
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC. Must be a /16 through /24."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR (e.g., 10.0.0.0/16)."
  }
}

variable "availability_zone_count" {
  description = "Number of availability zones to span. Subnets are calculated deterministically from this count."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 1 && var.availability_zone_count <= 6
    error_message = "availability_zone_count must be between 1 and 6."
  }
}

variable "enable_nat_gateway" {
  description = "When true, create NAT Gateway(s) for private subnet egress. When false, private subnets have no default route to the internet."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "When true, deploy a single shared NAT Gateway in the first public subnet (non-prod cost mode). When false, deploy one NAT Gateway per AZ for HA."
  type        = bool
  default     = true
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the module emits safe-but-immortal settings. When false
    (non-prod), it emits cycle-friendly settings so N-cycle tests can
    apply/destroy repeatedly without manual cleanup. This module exposes the
    variable for tag and policy consistency with other modules; the VPC itself
    has no AWS-native delete protection toggle.
  EOT
  type        = bool
  default     = false
}

variable "vpc_endpoints" {
  description = <<-EOT
    AWS service short names to create VPC endpoints for. Gateway endpoints
    (free) are created for s3 and dynamodb when present; everything else
    becomes an interface endpoint. Example: ["s3", "dynamodb", "ecr.api",
    "ecr.dkr", "logs", "sts", "secretsmanager"].
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.vpc_endpoints : can(regex("^[a-z0-9.-]+$", s))])
    error_message = "Each vpc_endpoints entry must be a lowercase service short name (e.g., s3, ecr.api, secretsmanager)."
  }
}
