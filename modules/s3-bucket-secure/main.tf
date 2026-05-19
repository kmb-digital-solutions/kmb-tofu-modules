###############################################################################
# Module: s3-bucket-secure
#
# Encrypted-by-default S3 bucket with TLS-only access, KMS PUT enforcement,
# public access locked off, BucketOwnerEnforced ownership (ACLs disabled),
# versioning on, and optional Object Lock COMPLIANCE.
#
# Pitfalls handled (see docs/module-development.md):
#   - force_destroy is bound to !destroy_protection: non-prod buckets
#     clear their object versions on destroy so the N-cycle can pass.
#   - Object Lock can ONLY be enabled at create. We refuse unless
#     destroy_protection = true, because the only legitimate consumer is
#     the hipaa-overlay module.
#   - Bucket name conflicts surface via bucket_name_override (predictable
#     names beat auto-suffixed collision-free ones).
#   - Bucket policy denies non-TLS and requires aws:kms SSE on PUT.
###############################################################################

locals {
  # `<customer>-<env>[-<app>]-<purpose>`. App-aware namespacing kicks in
  # when the caller passes a non-empty application_name.
  name_prefix_base      = var.application_name == "" ? "${var.customer_slug}-${var.environment}" : "${var.customer_slug}-${var.environment}-${var.application_name}"
  generated_bucket_name = "${local.name_prefix_base}-${var.purpose}"
  bucket_name           = coalesce(var.bucket_name_override, local.generated_bucket_name)

  tags = merge(
    {
      customer_slug = var.customer_slug
      environment   = var.environment
      module        = "s3-bucket-secure"
      managed_by    = "tofu"
      purpose       = var.purpose
    },
    var.application_name == "" ? {} : { application = var.application_name },
  )
}

###############################################################################
# Bucket
#
# The precondition enforces: Object Lock COMPLIANCE is only legitimate
# with destroy_protection on. The N-cycle test never exercises this
# combination because the hipaa-overlay module is excluded from the cycle.
###############################################################################

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name

  # force_destroy clears object versions during destroy. Required for the
  # N-cycle test on non-prod. Refused on prod to prevent fat-finger data
  # loss.
  force_destroy = !var.destroy_protection

  # Object Lock can only be enabled at create time; it cannot be added
  # later.
  object_lock_enabled = var.enable_object_lock_compliance

  tags = merge(local.tags, {
    Name = local.bucket_name
  })

  lifecycle {
    precondition {
      condition     = !var.enable_object_lock_compliance || var.destroy_protection
      error_message = "enable_object_lock_compliance requires destroy_protection = true. Only the hipaa-overlay module should set this."
    }
  }
}

###############################################################################
# Ownership, public access, encryption, versioning
###############################################################################

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    # Reduces KMS API calls by deriving per-object data keys from a
    # bucket-level data key. Required for cost on write-heavy buckets.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    # Always Enabled. force_destroy clears versions on non-prod destroy,
    # so this is N-cycle safe.
    status = "Enabled"
  }
}

###############################################################################
# Object Lock (COMPLIANCE) — HIPAA-overlay only
###############################################################################

resource "aws_s3_bucket_object_lock_configuration" "this" {
  count = var.enable_object_lock_compliance ? 1 : 0

  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      # Default 7-year retention; consumers (hipaa-overlay) can extend by
      # placing per-object retention headers. COMPLIANCE retention cannot
      # be shortened or removed by anyone.
      years = 7
    }
  }
}

###############################################################################
# Bucket policy: TLS-only + SSE-KMS on PUT
###############################################################################

data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyUnencryptedPut"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid    = "DenyWrongKmsKey"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # Must depend on the public access block so the policy isn't briefly
  # accepted on a still-publicly-accessible bucket.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

###############################################################################
# Lifecycle + CORS (opt-in)
###############################################################################

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count = length(var.lifecycle_rules) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = rule.value.enabled ? "Enabled" : "Disabled"

      filter {
        prefix = rule.value.filter_prefix
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days == null ? [] : [rule.value.expiration_days]
        content {
          days = expiration.value
        }
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_days == null ? [] : [rule.value.abort_incomplete_multipart_days]
        content {
          days_after_initiation = abort_incomplete_multipart_upload.value
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_expiration_days == null ? [] : [rule.value.noncurrent_version_expiration_days]
        content {
          noncurrent_days = noncurrent_version_expiration.value
        }
      }

      dynamic "transition" {
        for_each = rule.value.transitions
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }
    }
  }

  # Versioning must be configured before lifecycle rules that reference
  # noncurrent versions.
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_cors_configuration" "this" {
  count = length(var.cors_rules) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this.id

  dynamic "cors_rule" {
    for_each = var.cors_rules
    content {
      allowed_headers = cors_rule.value.allowed_headers
      allowed_methods = cors_rule.value.allowed_methods
      allowed_origins = cors_rule.value.allowed_origins
      expose_headers  = cors_rule.value.expose_headers
      max_age_seconds = cors_rule.value.max_age_seconds
    }
  }
}
