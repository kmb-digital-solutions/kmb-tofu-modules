output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "DNS name of the ALB (use for CNAME records or external integrations)."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone id of the ALB. Use when constructing alias records in zones outside this module."
  value       = aws_lb.this.zone_id
}

output "alb_security_group_id" {
  description = "Security group attached to the ALB. The caller MUST allow ingress on `container_port` from this SG on the workload's security group."
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "Target group the workload's ECS service / target should register with. Pass to ecs-service's `target_group_arn` input."
  value       = aws_lb_target_group.this.arn
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener. Useful when the caller wants to attach additional listener rules (path-based routing, host-header routing)."
  value       = aws_lb_listener.https.arn
}

output "https_certificate_arn" {
  description = "ARN of the certificate the HTTPS listener is using (ACM or IAM-uploaded, depending on https_cert_source)."
  value       = local.listener_certificate_arn
}

output "primary_fqdn" {
  description = "The primary FQDN the ALB answers on (echoed for caller convenience)."
  value       = var.primary_fqdn
}

output "primary_url" {
  description = "Full https:// URL for the primary FQDN."
  value       = "https://${var.primary_fqdn}"
}
