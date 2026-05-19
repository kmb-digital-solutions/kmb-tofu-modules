# alb-fronted-service

Internet-facing (or internal) ALB + target group + HTTPS listener + cert (ACM or
self-signed) + Route 53 alias record(s). Composes naturally with
`modules/ecs-service`: pass `target_group_arn` and `alb_security_group_id` to
the workload module and you have a complete app-behind-an-ALB.

This module deliberately does NOT call `ecs-service` itself, keeping the
"shared modules do not compose each other" discipline. The caller wires the
two together in 3 lines (target group ARN + SG rule).

## Usage

```hcl
resource "aws_security_group" "tasks" {
  name        = "${local.full_name}-tasks"
  description = "${var.service_name} ECS tasks"
  vpc_id      = module.vpc.vpc_id
  tags        = local.common_tags
}

# Tasks accept traffic only from the ALB SG.
resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = module.api_alb.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  description                  = "ALB to ${var.service_name} tasks"
}

resource "aws_vpc_security_group_egress_rule" "tasks_egress_all" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Egress to AWS APIs / Internet"
}

module "api_alb" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/alb-fronted-service?ref=main"

  customer_slug    = var.customer_slug
  environment      = var.environment
  application_name = "n8n"
  service_name     = "api"

  vpc_id                   = module.vpc.vpc_id
  public_subnet_ids        = module.vpc.public_subnet_ids
  target_security_group_id = aws_security_group.tasks.id

  container_port      = 5678
  health_check_path   = "/healthz"

  hosted_zone_id    = var.hosted_zone_id
  primary_fqdn      = "n8n-${var.environment}.${var.app_domain}"
  https_cert_source = var.https_cert_source  # "acm" or "self_signed"

  destroy_protection = var.destroy_protection
}

module "api_service" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/ecs-service?ref=main"

  customer_slug      = var.customer_slug
  environment        = var.environment
  application_name   = "n8n"
  service_name       = "api"

  cluster_arn        = module.ecs_cluster.cluster_arn
  container_image    = var.container_image    # e.g., "123.dkr.ecr...:n8n-1.43"
  container_port     = 5678
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [aws_security_group.tasks.id]
  target_group_arn   = module.api_alb.target_group_arn

  log_kms_key_arn       = module.kms.key_arns["logs"]
  enable_log_kms_policy = true
}
```

## Cert paths

- `https_cert_source = "acm"` — DNS-validated public certificate. **Requires the
  `hosted_zone_id` to be a PUBLIC Route 53 zone.** ACM's validators query
  public DNS to confirm zone control; a private zone cannot complete this
  validation and the certificate stays in `PENDING_VALIDATION` indefinitely
  (`tofu apply` then blocks on the `aws_acm_certificate_validation` resource
  for up to 75 minutes before timing out).

- `https_cert_source = "self_signed"` — A 2048-bit RSA self-signed certificate
  is generated at apply time via the `tls` provider and uploaded to IAM as
  a server certificate. ALB listeners accept either ACM ARNs or IAM
  server-certificate ARNs, so the listener config is identical. Browsers
  will show a warning on first load; pin the fingerprint or import the
  CA on test clients.

## SAN vs DNS alias

Two separate inputs control what the cert covers vs what gets a Route 53 record:

- `primary_fqdn` + `additional_san_fqdns` — what the cert is issued for.
- `dns_alias_fqdns` — which FQDNs get A-alias records pointing at this ALB.

This split matters when the same ALB serves multiple hostnames (cert covers
all of them) but only some hostnames live in this hosted zone (others are
provisioned elsewhere). Default `dns_alias_fqdns = []` means "create one
alias record at `primary_fqdn`."
