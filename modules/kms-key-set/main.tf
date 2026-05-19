###############################################################################
# Module: kms-key-set
#
# Creates one CMK + alias per purpose, with rotation enabled and a deletion
# window tied to var.destroy_protection. Optionally replicates each key to
# the aws.replica provider's region as a multi-region replica.
#
# Pitfalls handled (see docs/module-development.md):
#   - Alias is a separate aws_kms_alias resource. After tofu destroy, the
#     CMK enters pending-deletion (7 or 30 days). A subsequent apply
#     creates a NEW CMK; the alias resource rebinds cleanly because the
#     alias is its own AWS object.
#   - Multi-region keys use aws_kms_replica_key (not a second primary).
#     The replica shares key material with the primary; rotation propagates.
#   - Key policy here is intentionally minimal: root account full access.
#     Consuming modules add service-specific grants via aws_kms_grant or
#     by extending the policy in the application root. Centralizing every
#     service principal here would couple this module to every consumer.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # `<customer>-<env>[-<app>]`. App-aware namespacing kicks in when the
  # caller passes a non-empty application_name. Each purpose becomes its
  # own suffix on the alias name.
  name_prefix_base = var.application_name == "" ? "${var.customer_slug}-${var.environment}" : "${var.customer_slug}-${var.environment}-${var.application_name}"

  tags = merge(
    {
      customer_slug = var.customer_slug
      environment   = var.environment
      module        = "kms-key-set"
      managed_by    = "tofu"
    },
    var.application_name == "" ? {} : { application = var.application_name },
  )

  deletion_window_days = var.destroy_protection ? 30 : 7

  # Default statement on every key: root account full access. Callers extend
  # per-purpose via var.additional_policy_statements_by_purpose.
  root_statement = {
    Sid    = "RootAccountFullAccess"
    Effect = "Allow"
    Principal = {
      AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
    }
    Action   = "kms:*"
    Resource = "*"
  }

  # Composed policy per purpose: root + any caller-provided statements.
  key_policies = {
    for purpose in var.purposes : purpose => jsonencode({
      Version = "2012-10-17"
      Statement = concat(
        [local.root_statement],
        lookup(var.additional_policy_statements_by_purpose, purpose, []),
      )
    })
  }
}

###############################################################################
# Primary CMKs
###############################################################################

resource "aws_kms_key" "this" {
  for_each = toset(var.purposes)

  description             = "${local.name_prefix_base} ${each.value} CMK"
  deletion_window_in_days = local.deletion_window_days
  enable_key_rotation     = true
  multi_region            = var.enable_multi_region
  policy                  = local.key_policies[each.value]

  tags = merge(local.tags, {
    Name    = "${local.name_prefix_base}-${each.value}"
    purpose = each.value
  })
}

# Alias as its own resource so re-apply after destroy rebinds to a fresh key
# even while the previous key sits in the pending-deletion window.
resource "aws_kms_alias" "this" {
  for_each = toset(var.purposes)

  name          = "alias/${local.name_prefix_base}-${each.value}"
  target_key_id = aws_kms_key.this[each.value].key_id
}

###############################################################################
# Multi-region replicas (HIPAA-tier opt-in)
###############################################################################

resource "aws_kms_replica_key" "this" {
  for_each = var.enable_multi_region ? toset(var.purposes) : []

  provider = aws.replica

  description             = "${local.name_prefix_base} ${each.value} replica CMK"
  primary_key_arn         = aws_kms_key.this[each.value].arn
  deletion_window_in_days = local.deletion_window_days
  policy                  = local.key_policies[each.value]

  tags = merge(local.tags, {
    Name    = "${local.name_prefix_base}-${each.value}-replica"
    purpose = each.value
    role    = "replica"
  })
}

resource "aws_kms_alias" "replica" {
  for_each = var.enable_multi_region ? toset(var.purposes) : []

  provider = aws.replica

  name          = "alias/${local.name_prefix_base}-${each.value}"
  target_key_id = aws_kms_replica_key.this[each.value].key_id
}
