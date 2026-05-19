output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "CloudFront distribution ARN. Use in S3 bucket policies that scope OAC by aws:SourceArn (this module already does that for the origin bucket; surface for callers that bind additional buckets)."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "Default CloudFront domain (e.g., 'dxxxxxxxxx.cloudfront.net'). Useful for diagnostics; viewers should use the custom FQDN(s)."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "CloudFront-managed hosted zone id (Z2FDTNDATAQYW2). Use when constructing alias records to this distribution in zones outside this module."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "certificate_arn" {
  description = "ARN of the ACM certificate (in us-east-1) consumed by the distribution."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "origin_access_control_id" {
  description = "OAC id. Useful when binding additional CloudFront distributions to the same origin bucket via the same OAC."
  value       = aws_cloudfront_origin_access_control.this.id
}

output "primary_fqdn" {
  description = "The primary FQDN the distribution answers on (echoed for caller convenience)."
  value       = var.primary_fqdn
}

output "primary_url" {
  description = "Full https:// URL for the primary FQDN."
  value       = "https://${var.primary_fqdn}"
}
