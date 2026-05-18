variable "customer_slug" {
  description = "Customer slug used for naming and tagging. Lowercase alphanumeric and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.customer_slug))
    error_message = "customer_slug must be 3-40 chars, lowercase alphanumeric and hyphens, not start or end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, staging, prod."
  type        = string

  validation {
    condition     = can(regex("^(dev|staging|prod)$", var.environment))
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "engine_version" {
  description = "PostgreSQL engine version. The parameter group family is derived from the major version (e.g. '16.4' -> 'postgres16')."
  type        = string
  default     = "16.4"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?$", var.engine_version))
    error_message = "engine_version must be a Postgres version string like '16.4' or '15'."
  }
}

variable "instance_class" {
  description = "RDS instance class. Use Graviton (`db.t4g.*` / `db.m7g.*`) when available for cost/perf."
  type        = string
  default     = "db.t4g.medium"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class must match the AWS RDS class pattern, e.g. db.t4g.medium."
  }
}

variable "allocated_storage" {
  description = "Initial allocated storage in GB."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 65536
    error_message = "allocated_storage must be between 20 and 65536 GB."
  }
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GB. Must be >= allocated_storage. Set equal to allocated_storage to disable autoscaling."
  type        = number
  default     = 100

  validation {
    condition     = var.max_allocated_storage >= 20 && var.max_allocated_storage <= 65536
    error_message = "max_allocated_storage must be between 20 and 65536 GB."
  }
}

variable "multi_az" {
  description = "Enable Multi-AZ failover. Orthogonal to destroy_protection; non-prod typically uses single-AZ for cost."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Initial database name. Must be valid Postgres identifier (letters, digits, underscores; cannot start with a digit)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z_][a-zA-Z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must be 1-63 chars, start with a letter or underscore, contain only letters/digits/underscores."
  }
}

variable "master_username" {
  description = "Postgres master username. Must not be a reserved word ('admin', 'rdsadmin', 'postgres' are rejected by RDS)."
  type        = string
  default     = "app"

  validation {
    condition = (
      can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.master_username))
      && !contains(["admin", "rdsadmin", "postgres", "rds_superuser"], lower(var.master_username))
    )
    error_message = "master_username must be a valid Postgres identifier and not a reserved name (admin, rdsadmin, postgres, rds_superuser)."
  }
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group. RDS requires >= 2 subnets in different AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must contain at least 2 subnets in different AZs (RDS requirement)."
  }
}

variable "source_security_group_ids" {
  description = "Security group IDs allowed to connect to the DB on port 5432. Must contain at least one entry; an isolated DB serves no application traffic."
  type        = list(string)

  validation {
    condition     = length(var.source_security_group_ids) > 0
    error_message = "source_security_group_ids must contain at least one security group ID."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN for storage encryption, Secrets Manager secret encryption, and Performance Insights (if enabled). Required — RDS storage encryption is mandatory."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]+:key/[a-f0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a valid KMS key ARN."
  }
}

variable "parameter_overrides" {
  description = <<-EOT
    Additional Postgres parameter-group entries beyond the baseline
    (rds.force_ssl=1, log_connections=1, log_disconnections=1,
    log_min_duration_statement=1000). Values are strings; RDS coerces
    them per parameter type.
  EOT
  type        = map(string)
  default     = {}
}

variable "backup_retention_days" {
  description = "Automated backup retention in days. Overridden to 35 when destroy_protection is true."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 0 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 0 and 35."
  }
}

variable "enable_performance_insights" {
  description = "Enable RDS Performance Insights. Requires a CMK; the module reuses kms_key_arn for the PI key."
  type        = bool
  default     = false
}

variable "performance_insights_retention_days" {
  description = "Performance Insights retention. 7 (free tier) or 731 (long-term)."
  type        = number
  default     = 7

  validation {
    condition     = contains([7, 731], var.performance_insights_retention_days)
    error_message = "performance_insights_retention_days must be 7 or 731."
  }
}

variable "enable_iam_authentication" {
  description = "Enable IAM database authentication. Lets ECS task roles obtain short-lived tokens instead of using master password."
  type        = bool
  default     = true
}

variable "monitoring_interval_seconds" {
  description = "Enhanced Monitoring interval. 0 disables. Valid: 0, 1, 5, 10, 15, 30, 60."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval_seconds)
    error_message = "monitoring_interval_seconds must be one of 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the module emits safe-but-immortal settings:
    deletion_protection on, final snapshot taken, automated backups
    retained, apply_immediately disabled (changes wait for maintenance
    window), backup retention forced to 35 days, and the Secrets Manager
    secret recovery window set to 7 days. When false (non-prod), all of
    those flip to cycle-friendly values so N-cycle tests can apply and
    destroy the database repeatedly without manual cleanup.
  EOT
  type        = bool
  default     = false
}
