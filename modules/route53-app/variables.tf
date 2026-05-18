variable "customer_slug" {
  description = "Customer slug used for tagging. Lowercase alphanumeric and hyphens only."
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

variable "hosted_zone_id" {
  description = <<-EOT
    ID of the EXISTING Route 53 hosted zone (public or private) under which
    the records in var.records will be created. This module never creates
    hosted zones; zones are typically pre-existing customer assets that
    outlive any single application stack.
  EOT
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{4,}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must look like a Route 53 zone id (e.g., Z2FDTNDATAQYW2)."
  }
}

variable "records" {
  description = <<-EOT
    Records to manage in the hosted zone. Each entry creates one
    aws_route53_record. When alias_target is set, the record is created as
    an AWS alias (and var.records[*].records is ignored); otherwise literal
    rrdata values from var.records[*].records are written.

    Fields:
      name            Subdomain (e.g. "app" or "api.app"). The hosted zone's
                      apex is appended automatically by Route 53.
      type            One of A | AAAA | CNAME.
      ttl             Record TTL in seconds. Required for non-alias records;
                      ignored for alias records.
      records         Literal rrdata values. Required for non-alias records;
                      must be empty for alias records.
      alias_target    Optional. When set, the record becomes an alias to the
                      named AWS resource (ELB, CloudFront, API Gateway, etc.).
  EOT
  type = list(object({
    name    = string
    type    = string
    ttl     = number
    records = list(string)
    alias_target = optional(object({
      name                   = string
      zone_id                = string
      evaluate_target_health = bool
    }))
  }))

  validation {
    condition = alltrue([
      for r in var.records : contains(["A", "AAAA", "CNAME"], r.type)
    ])
    error_message = "Each record.type must be one of: A, AAAA, CNAME."
  }

  validation {
    condition = alltrue([
      for r in var.records : (r.alias_target != null) || (length(r.records) > 0)
    ])
    error_message = "Each non-alias record must have at least one entry in records."
  }

  validation {
    condition = alltrue([
      for r in var.records : (r.alias_target == null) || (length(r.records) == 0)
    ])
    error_message = "Alias records must have an empty records list (rrdata comes from alias_target)."
  }

  validation {
    condition = alltrue([
      for r in var.records : r.ttl >= 0 && r.ttl <= 86400
    ])
    error_message = "Each record.ttl must be between 0 and 86400 seconds."
  }

  validation {
    condition = length(distinct([
      for r in var.records : "${r.name}|${r.type}"
    ])) == length(var.records)
    error_message = "Each (name, type) pair must be unique within records."
  }
}

variable "destroy_protection" {
  description = <<-EOT
    Convention parameter — Route 53 records destroy cleanly with no AWS-native
    delete protection toggle, so this value is currently unused inside the
    module. It is accepted for variable-shape consistency with every other
    module in this repository so application roots can pass a single bool
    everywhere. Hosted zones themselves are intentionally out of scope; this
    module only manages records under an existing zone.
  EOT
  type        = bool
  default     = false
}
