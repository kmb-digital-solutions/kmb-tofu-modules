locals {
  base_tags = {
    customer_slug = var.customer_slug
    environment   = var.environment
    module        = "ecr-repo"
    managed_by    = "tofu"
  }

  encryption_configuration = var.kms_key_arn == null ? {
    encryption_type = "AES256"
    kms_key         = null
    } : {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.tagged_image_retention_count} tagged images."
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.tagged_image_retention_count
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images beyond the last ${var.untagged_image_retention_count}."
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = var.untagged_image_retention_count
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = var.image_tag_mutability
  force_delete         = !var.destroy_protection

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = local.encryption_configuration.encryption_type
    kms_key         = local.encryption_configuration.kms_key
  }

  tags = local.base_tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy     = local.lifecycle_policy
}
