# cloudfront-spa

CloudFront distribution + ACM certificate (in us-east-1) + Route 53 A-alias +
S3 OAC + bucket policy for an SPA served from a private S3 bucket, with
optional path-routed backend origin for the API tier.

Mirror image of `alb-fronted-service`: that module is "container behind an
ALB with HTTPS and DNS"; this module is "static assets behind CloudFront
with HTTPS and DNS, plus optional API path routing through the same
distribution."

## Usage

```hcl
# Private bucket holding the SPA bundle.
module "spa_bucket" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/s3-bucket-secure?ref=main"

  customer_slug    = var.customer_slug
  environment      = var.environment
  application_name = "spire"
  purpose          = "spa"
  kms_key_arn      = module.kms.key_arns["frontend"]
  destroy_protection = var.destroy_protection
}

# ALB-fronted backend service somewhere else in the root.
module "api_alb" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/alb-fronted-service?ref=main"
  # ...
  primary_fqdn = "api.spire-demo.singularsystems.dev"
  # ...
}

# CloudFront in front of the SPA bucket, with /api/* routed to the ALB.
module "spa" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/cloudfront-spa?ref=main"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  customer_slug    = var.customer_slug
  environment      = var.environment
  application_name = "spire"

  origin_bucket_id                  = module.spa_bucket.bucket_name
  origin_bucket_arn                 = module.spa_bucket.bucket_arn
  origin_bucket_regional_domain_name = module.spa_bucket.bucket_regional_domain_name

  hosted_zone_id = var.route53_hosted_zone_id
  primary_fqdn   = "app.spire-demo.singularsystems.dev"

  api_backend_origin_fqdn = module.api_alb.primary_fqdn
  api_path_pattern        = "/api/*"

  destroy_protection = var.destroy_protection
}
```

The caller's `versions.tf` declares both the default `aws` provider and an
`aws.us_east_1` alias (typically pointed at the same region as the default in
us-east-1-native stacks):

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region   # may not be us-east-1
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"  # CloudFront ACM certs MUST live here
}
```

## Why us-east-1 for the cert

ACM certificates consumed by CloudFront distributions are pulled from
us-east-1 specifically — even if the rest of the stack runs in any other
region. This is a CloudFront product constraint, not a module choice. The
module's `aws.us_east_1` provider alias forces the cert into that region;
the Route 53 validation records live in the customer's hosted zone (Route
53 is global so no alias needed) and the distribution itself is global.

## Backend origin + SNI

When `api_backend_origin_fqdn` is set, CloudFront uses `origin_protocol_policy
= "https-only"` and connects to the backend via its FQDN (not the raw ALB DNS
name). This means the backend's TLS cert MUST cover that FQDN — using the
ALB's `primary_fqdn` output from `alb-fronted-service` is the canonical
wiring, since that module's cert is issued for that exact name.

If the FQDN and the cert don't match, viewers see SSL_ERROR_BAD_CERT_DOMAIN
when the SPA tries to call `/api/*`. The `host_header_override` knob is
deliberately NOT exposed: forwarding the viewer's Host header (in
`api_forwarded_headers`) is the right answer when the backend cares about
the original host.

## SPA index fallback

`spa_index_fallback = true` (default) turns 403/404 origin responses into HTTP
200 returns of `/index.html`. Required for client-side routing (React Router,
Vue Router, etc.) so deep links resolve to the SPA shell which then routes
internally. Set false for static sites that own all their paths in S3.

## Outputs

| Output | Use |
|---|---|
| `primary_fqdn`, `primary_url` | The viewer-facing URL |
| `distribution_id`, `distribution_arn` | CloudFront ops — invalidations, alarms |
| `distribution_domain_name`, `distribution_hosted_zone_id` | For external Route 53 records in a different zone |
| `certificate_arn` | The ACM cert in us-east-1 |
| `origin_access_control_id` | When binding additional distributions to the same origin bucket |
