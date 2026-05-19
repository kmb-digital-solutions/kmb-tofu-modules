###############################################################################
# Module: cloudfront-spa
#
# CloudFront distribution + ACM certificate (in us-east-1) + Route 53 A-alias
# + S3 OAC + bucket policy for a single-page app served from a private S3
# bucket, with optional path-routed backend origin (e.g., /api/* forwarded to
# an ALB for backend calls).
#
# Composes cleanly with `s3-bucket-secure` (caller owns the bucket; this
# module attaches the OAC and bucket policy) and `alb-fronted-service` (this
# module consumes the ALB's primary_fqdn as the api_backend_origin_fqdn so
# CloudFront-to-ALB traffic is HTTPS end-to-end and SNI-correct against the
# ALB's cert).
#
# Provider note: ACM certs consumed by CloudFront MUST live in us-east-1.
# The caller declares an `aws.us_east_1` alias and passes it through; in
# stacks that already run in us-east-1 the alias is the same as the
# default provider.
###############################################################################

locals {
  # `<customer>-<env>[-<app>]-spa`
  name_prefix_base = var.application_name == "" ? "${var.customer_slug}-${var.environment}" : "${var.customer_slug}-${var.environment}-${var.application_name}"
  full_name        = "${local.name_prefix_base}-spa"

  cert_san_fqdns = distinct(concat([var.primary_fqdn], var.additional_san_fqdns))

  # CloudFront aliases = the cert's full coverage; the distribution serves
  # all configured names.
  distribution_aliases = local.cert_san_fqdns

  effective_dns_aliases = length(var.dns_alias_fqdns) == 0 ? [var.primary_fqdn] : var.dns_alias_fqdns

  api_origin_enabled = var.api_backend_origin_fqdn != ""

  base_tags = merge(
    {
      customer_slug = var.customer_slug
      environment   = var.environment
      module        = "cloudfront-spa"
      managed_by    = "tofu"
    },
    var.application_name == "" ? {} : { application = var.application_name },
    var.extra_tags,
  )
}

###############################################################################
# ACM certificate (us-east-1, required by CloudFront)
###############################################################################

resource "aws_acm_certificate" "this" {
  provider = aws.us_east_1

  domain_name               = var.primary_fqdn
  subject_alternative_names = length(local.cert_san_fqdns) > 1 ? slice(local.cert_san_fqdns, 1, length(local.cert_san_fqdns)) : []
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.base_tags, {
    Name = "${local.full_name}-cert"
  })
}

resource "aws_route53_record" "acm_validation" {
  # Validation records live in the customer's hosted zone (any region;
  # Route 53 is global, no provider alias needed).
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

###############################################################################
# Origin Access Control (replaces the older Origin Access Identity).
# OAC uses SigV4 to access S3 directly, with no public-bucket workarounds.
###############################################################################

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${local.full_name}-oac"
  description                       = "OAC for ${local.full_name} CloudFront distribution"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

###############################################################################
# CloudFront distribution
###############################################################################

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = var.ipv6_enabled
  comment         = "${local.full_name}"
  http_version    = "http2"
  price_class     = var.price_class

  aliases = local.distribution_aliases

  default_root_object = "index.html"

  # --- SPA bucket origin (private S3 via OAC) -------------------------------
  origin {
    domain_name              = var.origin_bucket_regional_domain_name
    origin_id                = "spa-bucket"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  # --- Backend HTTPS origin (optional) --------------------------------------
  dynamic "origin" {
    for_each = local.api_origin_enabled ? [1] : []
    content {
      domain_name = var.api_backend_origin_fqdn
      origin_id   = "backend"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  # --- Default behavior: SPA bucket -----------------------------------------
  default_cache_behavior {
    target_origin_id       = "spa-bucket"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = var.default_ttl_seconds
    max_ttl     = var.max_ttl_seconds
  }

  # --- Optional backend behavior: /api/* -> backend origin ------------------
  dynamic "ordered_cache_behavior" {
    for_each = local.api_origin_enabled ? [1] : []
    content {
      path_pattern           = var.api_path_pattern
      target_origin_id       = "backend"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      forwarded_values {
        query_string = true
        headers      = var.api_forwarded_headers
        cookies {
          forward = "all"
        }
      }

      # API responses are not cached by default; the backend owns its own
      # cache-control headers if any.
      min_ttl     = 0
      default_ttl = 0
      max_ttl     = 0
    }
  }

  # --- SPA index fallback: 403/404 -> /index.html ---------------------------
  # Required for client-side routing; SPAs return 404 from the origin for
  # any path that isn't a real S3 key, and the SPA needs to handle the route.
  dynamic "custom_error_response" {
    for_each = var.spa_index_fallback ? [403, 404] : []
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = var.minimum_tls_version
  }

  tags = merge(local.base_tags, {
    Name = local.full_name
  })
}

###############################################################################
# S3 bucket policy for CloudFront OAC
#
# Restricts s3:GetObject to the CloudFront service principal, scoped by
# aws:SourceArn so only THIS distribution can read THIS bucket.
###############################################################################

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.origin_bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = var.origin_bucket_id
  policy = data.aws_iam_policy_document.bucket_policy.json
}

###############################################################################
# Route 53 alias records (one per dns_alias_fqdns)
###############################################################################

resource "aws_route53_record" "alias" {
  for_each = toset(local.effective_dns_aliases)

  zone_id = var.hosted_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
