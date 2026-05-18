# route53-app
#
# Manages records under an existing Route 53 hosted zone. This module
# NEVER creates or deletes hosted zones — zones are pre-existing customer
# assets whose lifecycle outlives any single application stack. The
# module takes hosted_zone_id as an input and exits cleanly on every
# N-cycle.

locals {
  # Map of (name|type) → record object. Keyed this way so every record has
  # a stable for_each identity that survives reordering of the input list.
  records_by_key = {
    for r in var.records :
    "${r.name}|${r.type}" => r
  }

  common_tags = {
    customer_slug = var.customer_slug
    environment   = var.environment
    module        = "route53-app"
    managed_by    = "tofu"
  }
}

resource "aws_route53_record" "this" {
  for_each = local.records_by_key

  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type

  # Literal rrdata path: TTL + records list. Mutually exclusive with the
  # alias block. The variable validation guarantees exactly one is set.
  ttl     = each.value.alias_target == null ? each.value.ttl : null
  records = each.value.alias_target == null ? each.value.records : null

  dynamic "alias" {
    for_each = each.value.alias_target == null ? [] : [each.value.alias_target]
    content {
      name                   = alias.value.name
      zone_id                = alias.value.zone_id
      evaluate_target_health = alias.value.evaluate_target_health
    }
  }
}
