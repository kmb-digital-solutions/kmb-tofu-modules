###############################################################################
# Module: alb-fronted-service
#
# Inputs grouped by concern: identity, network, listener/cert, DNS, public
# access posture, ALB tuning. Every default is a non-prod-safe one — prod
# callers MUST opt in to deletion protection, restricted CIDRs, etc.
###############################################################################

# ---------- Identity --------------------------------------------------------

variable "customer_slug" {
  description = "Customer slug — used in resource names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.customer_slug))
    error_message = "customer_slug must be 3-40 chars, lowercase alphanumeric and hyphens, not starting or ending with a hyphen."
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
    Optional logical application slug (e.g., "spire", "traincover", "n8n").
    When non-empty, resource names are namespaced as
    `<customer_slug>-<environment>-<application_name>-<service_name>...`
    so multiple applications can coexist in the same customer+environment.
    Default empty preserves a `<customer_slug>-<environment>-<service_name>...`
    prefix.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.application_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.application_name))
    error_message = "application_name must be empty or 3-32 chars lowercase alphanumeric/hyphens, not starting or ending with a hyphen."
  }
}

variable "service_name" {
  description = "Logical service name (e.g., 'api'). Becomes the final segment of the ALB and target group names and the cert tag."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$", var.service_name))
    error_message = "service_name must be 2-32 chars, lowercase alphanumeric and hyphens, not starting or ending with a hyphen."
  }
}

# ---------- Network ---------------------------------------------------------

variable "vpc_id" {
  description = "VPC the ALB and target group live in. Must match the cluster/task VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like 'vpc-...'."
  }
}

variable "public_subnet_ids" {
  description = "Public subnet IDs the ALB attaches to. At least two for AZ spread."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "public_subnet_ids must contain at least 2 entries for HA."
  }
}

variable "target_security_group_id" {
  description = <<-EOT
    Security group attached to the ECS tasks (or other backend) that the ALB
    forwards to. The module creates an egress rule on the ALB SG permitting
    traffic to this SG on `container_port`. The caller is responsible for
    creating the matching ingress rule on the target SG, and for attaching
    `target_security_group_id` to the actual workload (ecs-service's
    `security_group_ids` input).
  EOT
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.target_security_group_id))
    error_message = "target_security_group_id must look like 'sg-...'."
  }
}

# ---------- Target group ----------------------------------------------------

variable "container_port" {
  description = "Backend port the target group forwards to (e.g., 8000 for FastAPI, 5678 for n8n)."
  type        = number

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535
    error_message = "container_port must be in [1, 65535]."
  }
}

variable "health_check_path" {
  description = "HTTP path the target group GETs to determine target health. Workload-defined."
  type        = string
  default     = "/health"

  validation {
    condition     = can(regex("^/.+", var.health_check_path))
    error_message = "health_check_path must start with '/'."
  }
}

variable "health_check_matcher" {
  description = "HTTP status code matcher for healthy targets (e.g., '200', '200-299')."
  type        = string
  default     = "200"
}

# ---------- HTTPS + cert ----------------------------------------------------

variable "primary_fqdn" {
  description = "Primary FQDN the listener cert is issued for and the alias record points at (e.g., 'api-dev.acme.app')."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", var.primary_fqdn))
    error_message = "primary_fqdn must be a valid lowercase FQDN."
  }
}

variable "additional_san_fqdns" {
  description = "Additional FQDNs to include as Subject Alternative Names on the cert (NOT created as DNS records by this module — see dns_alias_fqdns)."
  type        = list(string)
  default     = []
}

variable "dns_alias_fqdns" {
  description = <<-EOT
    FQDNs to create as Route 53 A-alias records pointing at the ALB. Each
    MUST be under the `hosted_zone_id` zone and MUST also be present in
    `primary_fqdn` or `additional_san_fqdns` (otherwise the listener cert
    won't cover the name). Default is just `[primary_fqdn]`.
  EOT
  type        = list(string)
  default     = []
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID owning every FQDN in primary_fqdn / additional_san_fqdns / dns_alias_fqdns."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.hosted_zone_id))
    error_message = "hosted_zone_id must look like a Route 53 zone id (e.g., 'Z2FDTNDATAQYW2')."
  }
}

variable "https_cert_source" {
  description = <<-EOT
    How to obtain the HTTPS certificate:

    * "acm"          — DNS-validated public ACM certificate. Requires
                       `hosted_zone_id` to be a PUBLIC Route 53 zone so
                       ACM's validators can resolve the validation records.
    * "self_signed"  — Generate a 2048-bit RSA self-signed certificate via
                       the `tls` provider and upload to IAM as a server
                       certificate. Use for non-production demos against
                       private zones. Browsers will warn on the cert.
  EOT
  type        = string
  default     = "acm"

  validation {
    condition     = contains(["acm", "self_signed"], var.https_cert_source)
    error_message = "https_cert_source must be one of: acm, self_signed."
  }
}

variable "ssl_policy" {
  description = "SSL policy for the HTTPS listener. Default ELBSecurityPolicy-TLS13-1-2-2021-06 (TLS 1.2+ with TLS 1.3)."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# ---------- Public ingress posture ------------------------------------------

variable "permitted_cidr_blocks" {
  description = "CIDRs allowed inbound on 443 and 80. Default ['0.0.0.0/0'] (open internet) — tighten for internal-only deployments."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_http_redirect" {
  description = "Create an HTTP:80 listener that 301-redirects to HTTPS. Default true. Set false for HTTPS-only ALBs (internal posture, no public HTTP traffic expected)."
  type        = bool
  default     = true
}

# ---------- ALB tuning ------------------------------------------------------

variable "internal" {
  description = "Make the ALB internal (private subnets, no public DNS). Default false (internet-facing)."
  type        = bool
  default     = false
}

variable "idle_timeout" {
  description = "ALB idle connection timeout in seconds."
  type        = number
  default     = 60

  validation {
    condition     = var.idle_timeout >= 1 && var.idle_timeout <= 4000
    error_message = "idle_timeout must be in [1, 4000]."
  }
}

variable "destroy_protection" {
  description = "When true, ALB deletion protection is enabled AND target group deregistration delay is set to a higher value to allow draining. Set true in prod."
  type        = bool
  default     = false
}

variable "extra_tags" {
  description = "Additional tags merged into all resource tags."
  type        = map(string)
  default     = {}
}
