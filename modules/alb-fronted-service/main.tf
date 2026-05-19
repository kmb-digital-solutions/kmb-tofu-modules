###############################################################################
# Module: alb-fronted-service
#
# Internet-facing (or internal) ALB + target group + HTTPS listener + ACM or
# self-signed certificate + Route 53 alias record(s). Designed to compose
# with the `ecs-service` module: the caller passes our `target_group_arn`
# and `alb_security_group_id` outputs into ecs-service and an ingress rule
# on the task SG, respectively. The actual workload (the ECS service) is
# NOT created by this module — keeps the "shared modules do not compose
# each other" discipline.
#
# Cert paths are mutually exclusive: when `https_cert_source = "acm"` we
# create an aws_acm_certificate + matching Route 53 validation records +
# an aws_acm_certificate_validation; when `https_cert_source = "self_signed"`
# we generate a 2048-bit RSA key + cert via the tls provider and upload as
# an aws_iam_server_certificate. The listener consumes the right ARN via
# local.listener_certificate_arn picked at plan time.
###############################################################################

locals {
  # `<customer>-<env>[-<app>]-<service>`. Per-resource Name uses this as the
  # consistent prefix; ALBs cap at 32 chars, target groups too — we'll truncate
  # via `name_prefix` (≤6 chars) on the LB so AWS appends the random suffix
  # within its own limit.
  name_prefix_base = var.application_name == "" ? "${var.customer_slug}-${var.environment}" : "${var.customer_slug}-${var.environment}-${var.application_name}"
  full_name        = "${local.name_prefix_base}-${var.service_name}"

  # Cert covers primary_fqdn + any additional SANs. Each unique to avoid
  # aws_acm_certificate validation errors on duplicate names.
  cert_san_fqdns = distinct(concat([var.primary_fqdn], var.additional_san_fqdns))

  # Default: create one alias record for the primary FQDN. Caller can override
  # with a list (e.g., both api-dev.acme.app and api.acme.app).
  effective_dns_aliases = length(var.dns_alias_fqdns) == 0 ? [var.primary_fqdn] : var.dns_alias_fqdns

  use_acm         = var.https_cert_source == "acm"
  use_self_signed = var.https_cert_source == "self_signed"

  base_tags = merge(
    {
      customer_slug = var.customer_slug
      environment   = var.environment
      service       = var.service_name
      module        = "alb-fronted-service"
      managed_by    = "tofu"
    },
    var.application_name == "" ? {} : { application = var.application_name },
    var.extra_tags,
  )
}

###############################################################################
# Security group for the ALB itself
#
# Ingress on 443 (and 80 when enable_http_redirect) from permitted_cidr_blocks.
# Egress is scoped to the workload SG on the container port — strict by
# default, since the ALB has no business reaching anything else.
###############################################################################

resource "aws_security_group" "alb" {
  name        = "${local.full_name}-alb"
  description = "Public ingress for the ${local.full_name} ALB; egress restricted to backend tasks."
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, {
    Name = "${local.full_name}-alb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.permitted_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from ${each.value}."
  tags              = local.base_tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = var.enable_http_redirect ? toset(var.permitted_cidr_blocks) : toset([])

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "HTTP from ${each.value} - redirected to HTTPS by the ALB listener."
  tags              = local.base_tags
}

resource "aws_vpc_security_group_egress_rule" "alb_to_target" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = var.target_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "Egress to ${var.service_name} tasks on the workload port."
  tags                         = local.base_tags
}

###############################################################################
# ACM cert path (https_cert_source = "acm")
###############################################################################

resource "aws_acm_certificate" "this" {
  count = local.use_acm ? 1 : 0

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
  for_each = local.use_acm ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.use_acm ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

###############################################################################
# Self-signed cert path (https_cert_source = "self_signed")
#
# Used for non-prod demos against private zones where ACM validation cannot
# complete. The cert is uploaded as an IAM server certificate; the ALB
# listener accepts either an ACM or IAM cert ARN.
###############################################################################

resource "tls_private_key" "this" {
  count = local.use_self_signed ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "this" {
  count = local.use_self_signed ? 1 : 0

  private_key_pem = tls_private_key.this[0].private_key_pem

  subject {
    common_name  = var.primary_fqdn
    organization = "Singular Systems (self-signed; ${var.environment})"
  }

  dns_names = local.cert_san_fqdns

  # 1-year validity. Non-prod environments are expected to rotate annually.
  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_iam_server_certificate" "this" {
  count = local.use_self_signed ? 1 : 0

  name_prefix      = "${local.full_name}-"
  certificate_body = tls_self_signed_cert.this[0].cert_pem
  private_key      = tls_private_key.this[0].private_key_pem

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.base_tags, {
    Name = "${local.full_name}-cert"
  })
}

locals {
  listener_certificate_arn = local.use_acm ? aws_acm_certificate_validation.this[0].certificate_arn : aws_iam_server_certificate.this[0].arn
}

###############################################################################
# ALB + target group + listeners
###############################################################################

resource "aws_lb" "this" {
  # ALB names cap at 32 chars. Use name_prefix (≤6 chars) so AWS handles the
  # uniqueness suffix; full_name moves to a Name tag.
  name_prefix                = substr(var.service_name, 0, 6)
  internal                   = var.internal
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.destroy_protection
  idle_timeout               = var.idle_timeout

  tags = merge(local.base_tags, {
    Name = "${local.full_name}-alb"
  })
}

resource "aws_lb_target_group" "this" {
  name_prefix = substr(var.service_name, 0, 6)
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = var.health_check_matcher
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Quick deregister on non-prod so N-cycle teardown doesn't wait 5min.
  deregistration_delay = var.destroy_protection ? 30 : 0

  lifecycle {
    # name_prefix forces replace-on-change; let new TG come up before old goes.
    create_before_destroy = true
  }

  tags = merge(local.base_tags, {
    Name = "${local.full_name}-tg"
  })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = local.listener_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.base_tags
}

resource "aws_lb_listener" "http_redirect" {
  count = var.enable_http_redirect ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.base_tags
}

###############################################################################
# Route 53 alias records
#
# One A-alias per FQDN in `dns_alias_fqdns` (or just primary_fqdn by default).
# All point at the same ALB DNS name + zone id.
###############################################################################

resource "aws_route53_record" "alias" {
  for_each = toset(local.effective_dns_aliases)

  zone_id = var.hosted_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
