###############################################################################
# Identity
###############################################################################

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
    Optional logical application slug (e.g., "spire", "n8n"). When non-empty,
    OAC and distribution Name tags are namespaced as
    `<customer_slug>-<environment>-<application_name>-spa` so multiple apps
    can coexist. Default empty preserves `<customer_slug>-<environment>-spa`.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.application_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.application_name))
    error_message = "application_name must be empty or 3-32 chars lowercase alphanumeric/hyphens, not starting or ending with a hyphen."
  }
}

###############################################################################
# Origin bucket (caller-owned)
###############################################################################

variable "origin_bucket_id" {
  description = "S3 bucket id (name) hosting the SPA assets. The caller creates the bucket (usually via modules/s3-bucket-secure) and this module attaches the CloudFront OAC + bucket policy."
  type        = string
}

variable "origin_bucket_arn" {
  description = "S3 bucket ARN — used in the bucket policy Resource clause."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:s3:::.+$", var.origin_bucket_arn))
    error_message = "origin_bucket_arn must be a valid S3 bucket ARN."
  }
}

variable "origin_bucket_regional_domain_name" {
  description = "S3 bucket regional domain name (e.g., 'my-bucket.s3.us-east-1.amazonaws.com'). The CloudFront origin uses this exact string."
  type        = string
}

###############################################################################
# DNS + TLS
###############################################################################

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID owning every FQDN in primary_fqdn / additional_san_fqdns / dns_alias_fqdns. MUST be a PUBLIC zone — ACM DNS validation requires public DNS resolution."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.hosted_zone_id))
    error_message = "hosted_zone_id must look like a Route 53 zone id (e.g., 'Z2FDTNDATAQYW2')."
  }
}

variable "primary_fqdn" {
  description = "Primary FQDN the SPA is served at. Becomes the CloudFront alias's first entry, the ACM cert's CN, and (by default) the only Route 53 alias record."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", var.primary_fqdn))
    error_message = "primary_fqdn must be a valid lowercase FQDN."
  }
}

variable "additional_san_fqdns" {
  description = "Additional FQDNs included as Subject Alternative Names on the ACM cert AND as CloudFront aliases (the distribution serves all of them). NOT created as Route 53 records by this module — see dns_alias_fqdns."
  type        = list(string)
  default     = []
}

variable "dns_alias_fqdns" {
  description = "FQDNs created as Route 53 A-alias records pointing at this CloudFront distribution. Default is just `[primary_fqdn]`. Each MUST also appear in primary_fqdn or additional_san_fqdns so the cert covers it."
  type        = list(string)
  default     = []
}

variable "minimum_tls_version" {
  description = "Minimum TLS version CloudFront serves to viewers. Modern apps should use TLSv1.2_2021 (default) or TLSv1.3_2022."
  type        = string
  default     = "TLSv1.2_2021"

  validation {
    condition     = contains(["TLSv1.2_2018", "TLSv1.2_2019", "TLSv1.2_2021", "TLSv1.3_2022"], var.minimum_tls_version)
    error_message = "minimum_tls_version must be a CloudFront-supported security policy (TLSv1.2_2018, TLSv1.2_2019, TLSv1.2_2021, TLSv1.3_2022)."
  }
}

###############################################################################
# SPA caching + fallback
###############################################################################

variable "default_ttl_seconds" {
  description = "Default CloudFront cache TTL in seconds for the SPA bucket origin. SPA static assets benefit from caching; the bundler hashes filenames so cache invalidation isn't needed for new deploys."
  type        = number
  default     = 3600

  validation {
    condition     = var.default_ttl_seconds >= 0 && var.default_ttl_seconds <= 31536000
    error_message = "default_ttl_seconds must be in [0, 31536000] (one year)."
  }
}

variable "max_ttl_seconds" {
  description = "Maximum CloudFront cache TTL."
  type        = number
  default     = 86400
}

variable "spa_index_fallback" {
  description = "Return /index.html with HTTP 200 for viewer requests that produce a 403 or 404 from the origin. Required when the SPA owns client-side routing (React Router, Vue Router, etc.) and the bucket has no fallback object."
  type        = bool
  default     = true
}

###############################################################################
# Optional backend origin (API path routing)
###############################################################################

variable "api_backend_origin_fqdn" {
  description = "Optional. FQDN of a backend ALB or HTTP origin to forward `var.api_path_pattern` requests to. When empty, no backend origin is created and no API cache behavior is registered. The origin uses HTTPS (origin_protocol_policy='https-only'); the FQDN MUST be served by something with a valid TLS cert for that name."
  type        = string
  default     = ""
}

variable "api_path_pattern" {
  description = "Path pattern routed to the api_backend_origin_fqdn (e.g., '/api/*'). Ignored when api_backend_origin_fqdn is empty."
  type        = string
  default     = "/api/*"
}

variable "api_forwarded_headers" {
  description = "Headers forwarded to the backend origin. Default ['Authorization','Host','Origin'] supports a Bearer-token SPA against a same-origin API."
  type        = list(string)
  default     = ["Authorization", "Host", "Origin"]
}

###############################################################################
# Lifecycle + cost
###############################################################################

variable "price_class" {
  description = "CloudFront edge location footprint. 'PriceClass_100' = North America + Europe (cheapest). 'PriceClass_200' = adds Asia, Middle East, Africa. 'PriceClass_All' = global."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

variable "geo_restriction_type" {
  description = "CloudFront geo restriction type. 'none' (default), 'whitelist' (locations are allowed), 'blacklist' (locations are blocked)."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "whitelist", "blacklist"], var.geo_restriction_type)
    error_message = "geo_restriction_type must be one of: none, whitelist, blacklist."
  }
}

variable "geo_restriction_locations" {
  description = "ISO 3166-1-alpha-2 country codes for geo restriction. Empty when geo_restriction_type='none'."
  type        = list(string)
  default     = []
}

variable "ipv6_enabled" {
  description = "Enable IPv6 on the distribution."
  type        = bool
  default     = true
}

variable "destroy_protection" {
  description = "When true, the distribution is set to 'enabled = true' on destroy attempt (CloudFront still requires disable-then-delete; this is metadata). Reserved for future tightening."
  type        = bool
  default     = false
}

variable "extra_tags" {
  description = "Additional tags merged into all resource tags."
  type        = map(string)
  default     = {}
}
