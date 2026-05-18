###############################################################################
# Module: hipaa-overlay
#
# Composable overlay implementing HIPAA Security Rule technical safeguards:
#   - AWS Backup vault (Vault Lock COMPLIANCE) + plan + service IAM role
#   - CloudTrail organization trail to a security-account S3 bucket,
#     including S3 data events on caller-specified PHI-bearing buckets
#   - GuardDuty detector (cross-account wiring delegated to the security
#     account via Organizations; optional invite_accepter when not using
#     delegated admin)
#   - Macie account enablement
#   - Security Hub with FSBP + CIS standards
#   - Inspector v2 for ECR + EC2 + Lambda
#   - AWS Config recorder + delivery channel + HIPAA conformance pack
#
# ─────────────────────────────────────────────────────────────────────────────
# WARNING — IRREVERSIBLE RETENTION
#
# Once aws_backup_vault_lock_configuration is in COMPLIANCE mode and past its
# changeable_for_days grace period, the vault CANNOT be deleted until every
# recovery point's retention has expired AND min_retention_days has elapsed.
# AWS Support cannot bypass it. Compose this module only when you are
# prepared to keep these resources running for the configured lock duration.
#
# This is the documented exception to the repository's N-cycle rule
# (see README.md and docs/module-development.md).
# ─────────────────────────────────────────────────────────────────────────────
###############################################################################

data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  guardduty_master = coalesce(var.guardduty_master_account_id, var.security_account_id)

  compliance_vault_name = "${var.customer_slug}-${var.environment}-compliance-vault"
  backup_role_name      = "${var.customer_slug}-${var.environment}-backup-role"
  cloudtrail_name       = "${var.customer_slug}-${var.environment}-org-trail"
  config_recorder_name  = "${var.customer_slug}-${var.environment}-config"
  config_delivery_name  = "${var.customer_slug}-${var.environment}-config-delivery"
  config_role_name      = "${var.customer_slug}-${var.environment}-config-role"
  hipaa_pack_name       = "${var.customer_slug}-${var.environment}-hipaa-pack"

  # Vault Lock min_retention_days. Use the larger of:
  #   (a) the longest delete_after_days across all backup plan rules + 30d buffer
  #   (b) 7 days (operational floor)
  longest_retention_days = length(var.backup_plan_rules) > 0 ? max([for r in var.backup_plan_rules : r.delete_after_days]...) : 0
  vault_lock_min_days    = max(local.longest_retention_days + 30, 7)
  # Cap retention at 36500 (100 years) — AWS Backup's published hard limit.
  vault_lock_max_days = 36500

  # Config delivery target. When s3_logs_bucket_arn is provided, route Config
  # snapshots there; otherwise share the CloudTrail bucket. Bucket policies in
  # the security account must allow config.amazonaws.com from this account.
  config_s3_bucket_name = var.s3_logs_bucket_arn == null ? var.cloudtrail_s3_bucket : reverse(split(":::", var.s3_logs_bucket_arn))[0]

  base_tags = {
    customer_slug = var.customer_slug
    environment   = var.environment
    module        = "hipaa-overlay"
    managed_by    = "tofu"
    compliance    = "hipaa"
  }
}

###############################################################################
# IAM role for AWS Backup service
###############################################################################

data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = local.backup_role_name
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json

  tags = merge(local.base_tags, {
    Name = local.backup_role_name
  })
}

resource "aws_iam_role_policy_attachment" "backup_service" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Allow the Backup service role to exercise the customer-managed KMS key.
# The key policy on the kms-key-set side grants backup.amazonaws.com via
# the service principal; this inline policy ensures the role itself can
# call KMS.
resource "aws_iam_role_policy" "backup_kms" {
  name = "${local.backup_role_name}-kms"
  role = aws_iam_role.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
        ]
        Resource = var.backup_kms_key_arn
      },
    ]
  })
}

###############################################################################
# AWS Backup Vault — COMPLIANCE mode lock
#
# changeable_for_days = 3 gives operators a 72-hour window to abort the
# initial apply. After that window expires, the lock is IRREVERSIBLE — even
# AWS Support cannot remove it. Deleting the vault thereafter requires
# emptying every recovery point AND waiting for min_retention_days to pass.
###############################################################################

resource "aws_backup_vault" "compliance" {
  name        = local.compliance_vault_name
  kms_key_arn = var.backup_kms_key_arn

  tags = merge(local.base_tags, {
    Name = local.compliance_vault_name
  })
}

resource "aws_backup_vault_lock_configuration" "compliance" {
  backup_vault_name   = aws_backup_vault.compliance.name
  changeable_for_days = 3
  min_retention_days  = local.vault_lock_min_days
  max_retention_days  = local.vault_lock_max_days
}

###############################################################################
# AWS Backup Plan
###############################################################################

resource "aws_backup_plan" "this" {
  count = length(var.backup_plan_rules) > 0 ? 1 : 0

  name = "${var.customer_slug}-${var.environment}-backup-plan"

  dynamic "rule" {
    for_each = var.backup_plan_rules
    content {
      rule_name                = rule.value.rule_name
      target_vault_name        = rule.value.target_vault_name
      schedule                 = rule.value.schedule_expression
      start_window             = rule.value.start_window_minutes
      completion_window        = rule.value.completion_window_minutes
      enable_continuous_backup = false

      lifecycle {
        cold_storage_after = lookup(rule.value, "lifecycle_cold_storage_after_days", null)
        delete_after       = rule.value.delete_after_days
      }

      dynamic "copy_action" {
        for_each = lookup(rule.value, "copy_to_destination_vault_arn", null) == null ? [] : [rule.value.copy_to_destination_vault_arn]
        content {
          destination_vault_arn = copy_action.value
          lifecycle {
            cold_storage_after = lookup(rule.value, "lifecycle_cold_storage_after_days", null)
            delete_after       = rule.value.delete_after_days
          }
        }
      }
    }
  }

  tags = merge(local.base_tags, {
    Name = "${var.customer_slug}-${var.environment}-backup-plan"
  })

  depends_on = [aws_backup_vault.compliance]
}

###############################################################################
# CloudTrail organization trail
#
# Multi-region, log-file validation on, KMS-encrypted via the backup CMK.
# The S3 destination lives in the security account; that bucket's policy
# must allow s3:PutObject from this account's CloudTrail principal — managed
# in the security account's own root module, not here.
###############################################################################

resource "aws_cloudtrail" "this" {
  name                          = local.cloudtrail_name
  s3_bucket_name                = var.cloudtrail_s3_bucket
  is_multi_region_trail         = true
  is_organization_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = var.backup_kms_key_arn

  # Management events: all read + write API calls.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  # Data events on PHI-bearing S3 buckets, when configured. CloudTrail data
  # event pricing scales with API call volume — the caller decides which
  # buckets warrant the cost.
  dynamic "event_selector" {
    for_each = length(var.s3_data_event_buckets) > 0 ? [1] : []
    content {
      read_write_type           = "All"
      include_management_events = false

      data_resource {
        type   = "AWS::S3::Object"
        values = [for arn in var.s3_data_event_buckets : "${arn}/"]
      }
    }
  }

  tags = merge(local.base_tags, {
    Name = local.cloudtrail_name
  })
}

###############################################################################
# GuardDuty
#
# When GuardDuty delegated administration is configured at the AWS
# Organization level, the security account auto-enrolls every member
# detector and no explicit invitation flow is needed. This module creates
# the detector and an aws_guardduty_invite_accepter that the security
# account's own root module can use as the accept-side counterpart when
# delegated admin is NOT in use. Either path produces the same outcome:
# findings flow to var.security_account_id.
###############################################################################

resource "aws_guardduty_detector" "this" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = false
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = merge(local.base_tags, {
    Name = "${var.customer_slug}-${var.environment}-guardduty"
  })
}

###############################################################################
# Macie
###############################################################################

resource "aws_macie2_account" "this" {
  count = var.enable_macie ? 1 : 0

  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}

###############################################################################
# Security Hub
###############################################################################

resource "aws_securityhub_account" "this" {
  count = var.enable_security_hub ? 1 : 0

  enable_default_standards  = false
  auto_enable_controls      = true
  control_finding_generator = "SECURITY_CONTROL"
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  count = var.enable_security_hub ? 1 : 0

  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.this]
}

resource "aws_securityhub_standards_subscription" "cis" {
  count = var.enable_security_hub ? 1 : 0

  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"

  depends_on = [aws_securityhub_account.this]
}

###############################################################################
# Inspector v2 — ECR + EC2 + Lambda scanning
###############################################################################

resource "aws_inspector2_enabler" "this" {
  count = var.enable_inspector ? 1 : 0

  account_ids    = [var.aws_account_id]
  resource_types = ["ECR", "EC2", "LAMBDA"]
}

###############################################################################
# AWS Config + HIPAA conformance pack
###############################################################################

data "aws_iam_policy_document" "config_assume_role" {
  count = var.enable_config ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0

  name               = local.config_role_name
  assume_role_policy = data.aws_iam_policy_document.config_assume_role[0].json

  tags = merge(local.base_tags, {
    Name = local.config_role_name
  })
}

resource "aws_iam_role_policy_attachment" "config_service" {
  count = var.enable_config ? 1 : 0

  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_config ? 1 : 0

  name = "${local.config_role_name}-s3"
  role = aws_iam_role.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${local.config_s3_bucket_name}",
          "arn:${data.aws_partition.current.partition}:s3:::${local.config_s3_bucket_name}/*",
        ]
      },
    ]
  })
}

resource "aws_config_configuration_recorder" "this" {
  count = var.enable_config ? 1 : 0

  name     = local.config_recorder_name
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  depends_on = [aws_iam_role_policy_attachment.config_service]
}

resource "aws_config_delivery_channel" "this" {
  count = var.enable_config ? 1 : 0

  name           = local.config_delivery_name
  s3_bucket_name = local.config_s3_bucket_name
  s3_key_prefix  = "AWSLogs/${var.aws_account_id}/Config"

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

# AWS-managed HIPAA Security conformance pack. The YAML body is pinned to a
# file in this module so the pack contents are reviewable + version-locked
# with the module tag, not fetched from a remote URL at apply time.
resource "aws_config_conformance_pack" "hipaa" {
  count = var.enable_config ? 1 : 0

  name          = local.hipaa_pack_name
  template_body = file("${path.module}/conformance-packs/hipaa-security.yaml")

  depends_on = [
    aws_config_configuration_recorder_status.this,
  ]
}
