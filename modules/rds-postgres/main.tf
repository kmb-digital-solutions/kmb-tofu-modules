locals {
  name_prefix = "${var.customer_slug}-${var.environment}"
  identifier  = "${local.name_prefix}-postgres"

  # Postgres major version drives the parameter-group family.
  # "16.4" -> "postgres16"; "15" -> "postgres15".
  engine_major_version   = split(".", var.engine_version)[0]
  parameter_group_family = "postgres${local.engine_major_version}"

  base_tags = {
    customer_slug = var.customer_slug
    environment   = var.environment
    module        = "rds-postgres"
    managed_by    = "tofu"
  }

  # Baseline parameters: SSL enforced, connection logging, slow-query log.
  # Merged with caller overrides; caller wins on conflict.
  baseline_parameters = {
    "rds.force_ssl"              = "1"
    "log_connections"            = "1"
    "log_disconnections"         = "1"
    "log_min_duration_statement" = "1000"
  }

  effective_parameters = merge(local.baseline_parameters, var.parameter_overrides)

  effective_backup_retention = var.destroy_protection ? 35 : var.backup_retention_days
  effective_recovery_window  = var.destroy_protection ? 7 : 0
}

# ---------- Subnet group ----------

resource "aws_db_subnet_group" "this" {
  name       = local.identifier
  subnet_ids = var.subnet_ids
  tags       = local.base_tags
}

# ---------- Parameter group ----------

resource "aws_db_parameter_group" "this" {
  name        = local.identifier
  family      = local.parameter_group_family
  description = "Parameters for ${local.identifier} (${var.engine_version})."

  dynamic "parameter" {
    for_each = local.effective_parameters
    content {
      name  = parameter.key
      value = parameter.value
      # rds.force_ssl + log_* require a reboot to apply.
      apply_method = "pending-reboot"
    }
  }

  tags = local.base_tags

  lifecycle {
    # New parameters force replacement; keep the old PG until the new
    # one is registered so the DB never references a destroyed PG.
    create_before_destroy = true
  }
}

# ---------- Security group ----------

# Derive the VPC ID from the first subnet rather than asking the caller
# for it — this enforces "DB SG is in the same VPC as the subnets" by
# construction and removes a foot-gun variable.
data "aws_subnet" "first" {
  id = var.subnet_ids[0]
}

resource "aws_security_group" "this" {
  name        = "${local.identifier}-db"
  description = "Allow 5432 to ${local.identifier} from declared source SGs only."
  vpc_id      = data.aws_subnet.first.vpc_id

  tags = local.base_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_source_sgs" {
  for_each = var.source_security_group_ids

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Postgres from ${each.key} SG."
  tags                         = local.base_tags
}

# Explicit egress to anywhere; RDS rarely initiates connections, but the
# default-empty egress on managed SGs has bitten too many teams.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress."
  tags              = local.base_tags
}

# ---------- Master password + Secrets Manager ----------

resource "random_password" "master" {
  length  = 32
  special = true
  # RDS rejects /, @, ", and spaces in master passwords.
  override_special = "!#$%&*()_+-=[]{}<>?"
}

resource "aws_secretsmanager_secret" "master" {
  name                    = "${local.identifier}/master-credentials"
  description             = "Master Postgres credentials for ${local.identifier}. Rotation managed out-of-module."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = local.effective_recovery_window
  tags                    = local.base_tags
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    engine   = "postgres"
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.db_name
  })
}

# ---------- Enhanced Monitoring role ----------

data "aws_iam_policy_document" "monitoring_assume" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  name               = "${local.identifier}-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume[0].json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval_seconds > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------- DB instance ----------

resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az

  iam_database_authentication_enabled = var.enable_iam_authentication

  backup_retention_period  = local.effective_backup_retention
  backup_window            = "03:00-04:00"
  maintenance_window       = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = !var.destroy_protection

  performance_insights_enabled    = var.enable_performance_insights
  performance_insights_kms_key_id = var.enable_performance_insights ? var.kms_key_arn : null
  performance_insights_retention_period = (
    var.enable_performance_insights ? var.performance_insights_retention_days : null
  )

  monitoring_interval = var.monitoring_interval_seconds
  monitoring_role_arn = var.monitoring_interval_seconds > 0 ? aws_iam_role.monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  deletion_protection       = var.destroy_protection
  skip_final_snapshot       = !var.destroy_protection
  final_snapshot_identifier = var.destroy_protection ? "${local.identifier}-final" : null
  apply_immediately         = !var.destroy_protection

  auto_minor_version_upgrade = true

  tags = local.base_tags

  lifecycle {
    # Rotating the master password out-of-band is the operator's job;
    # the module sets it once on create and ignores subsequent drift.
    ignore_changes = [password]
  }

  depends_on = [
    aws_db_subnet_group.this,
    aws_db_parameter_group.this,
    aws_security_group.this,
  ]
}
