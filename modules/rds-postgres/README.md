# modules/rds-postgres

One Postgres RDS instance with:

- Encrypted gp3 storage backed by the caller-supplied CMK.
- Custom parameter group with `rds.force_ssl=1`, connection/disconnect
  logging, and 1-second slow query logging (override via
  `parameter_overrides`).
- Dedicated security group permitting 5432 only from declared source
  SGs.
- Random master password persisted to Secrets Manager (CMK-encrypted),
  with the connection envelope (`{username, password, engine, host,
  port, dbname}`) ready for application consumption.
- IAM database authentication on by default.
- Optional Multi-AZ, Performance Insights, and Enhanced Monitoring.

## Usage

```hcl
module "rds_app" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/rds-postgres?ref=rds-postgres/v1.0.0"

  customer_slug = var.customer_slug
  environment   = var.environment

  engine_version    = "16.4"
  instance_class    = "db.t4g.medium"
  allocated_storage = 20
  multi_az          = var.destroy_protection

  db_name                   = "appdb"
  subnet_ids                = module.vpc.private_subnet_ids
  source_security_group_ids = [aws_security_group.api_tasks.id]
  kms_key_arn               = module.kms.rds_key_arn

  parameter_overrides = {
    "shared_preload_libraries" = "pg_stat_statements"
  }

  enable_performance_insights = true
  enable_iam_authentication   = true
  monitoring_interval_seconds = 60

  destroy_protection = var.destroy_protection
}
```

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | string | — | Customer slug. |
| `environment` | string | — | `dev` / `staging` / `prod`. |
| `engine_version` | string | `"16.4"` | Postgres version; family derived from major version. |
| `instance_class` | string | `"db.t4g.medium"` | RDS instance class. |
| `allocated_storage` | number | `20` | Initial storage GB. |
| `max_allocated_storage` | number | `100` | Storage autoscaling ceiling. |
| `multi_az` | bool | `false` | Multi-AZ failover. |
| `db_name` | string | — | Initial database name. |
| `master_username` | string | `"app"` | Master username (`admin`, `rdsadmin`, `postgres` are rejected). |
| `subnet_ids` | list(string) | — | ≥ 2 subnets in different AZs. |
| `source_security_group_ids` | list(string) | — | Caller SGs permitted on 5432. |
| `kms_key_arn` | string | — | CMK for storage, Secrets Manager secret, and PI. |
| `parameter_overrides` | map(string) | `{}` | Extra parameter-group entries. |
| `backup_retention_days` | number | `7` | Automated backup retention. Forced to 35 when destroy_protection is true. |
| `enable_performance_insights` | bool | `false` | Enable PI (uses kms_key_arn). |
| `performance_insights_retention_days` | number | `7` | 7 or 731. |
| `enable_iam_authentication` | bool | `true` | Enable IAM DB auth. |
| `monitoring_interval_seconds` | number | `0` | Enhanced Monitoring interval (0 disables). |
| `destroy_protection` | bool | `false` | See behavior matrix below. |

## Outputs

| Name | Description |
|------|-------------|
| `endpoint` | RDS endpoint hostname. |
| `port` | 5432. |
| `db_name` | Initial database name. |
| `master_username` | Master username. |
| `master_password_secret_arn` | Secrets Manager ARN for credentials. |
| `security_group_id` | DB SG ID. |
| `instance_arn` | RDS instance ARN. |
| `instance_id` | RDS instance identifier. |

## Pitfalls handled

- **`skip_final_snapshot = !var.destroy_protection`.** Non-prod
  destroys skip the 3-5 minute snapshot wait. Prod requires the
  snapshot, named `<identifier>-final`.
- **`delete_automated_backups = !var.destroy_protection`.** Without
  this, old automated snapshots linger and block parameter-group
  destroy on the next cycle.
- **`apply_immediately = !var.destroy_protection`.** Without this, a
  parameter-group change queues into a maintenance window that
  survives the destroy step and re-applies on the next instance with
  the same name.
- **`backup_retention_period` is overridden to 35 days when destroy
  protection is on.** Production databases keep the maximum AWS
  retention regardless of `var.backup_retention_days`.
- **`recovery_window_in_days` on the master secret is 0 in non-prod**
  so the secret name is immediately reusable on the next cycle. Prod
  uses 7 days for the standard "oh, I needed that" grace window.
- **`final_snapshot_identifier` is set only when destroy_protection is
  true.** Setting it unconditionally and combining with
  `skip_final_snapshot = true` produces an unused argument.
- **`create_before_destroy` on the parameter group and security
  group.** Both have name-uniqueness constraints; the lifecycle
  pragma lets a replace happen in one apply without colliding with
  the old resource.
- **`ignore_changes = [password]` on the DB instance.** Operators may
  rotate the master password out-of-band (or via Secrets Manager
  rotation); the module sets it once on create and never argues with
  the live value afterward.
- **`vpc_id` is derived from `subnet_ids[0]`** via a data source rather
  than asked of the caller. This makes "DB SG in wrong VPC" structurally
  impossible.
- **Master username denylist.** `admin`, `rdsadmin`, `postgres`, and
  `rds_superuser` are rejected at variable validation time — RDS
  rejects them at creation time with a less actionable error.

## `destroy_protection` behavior

| Setting | `false` (non-prod) | `true` (prod) |
|---------|-------------------|---------------|
| `deletion_protection` | `false` | `true` |
| `skip_final_snapshot` | `true` | `false` |
| `final_snapshot_identifier` | `null` | `<id>-final` |
| `delete_automated_backups` | `true` | `false` |
| `apply_immediately` | `true` | `false` |
| `backup_retention_period` | `var.backup_retention_days` | `35` |
| Secrets Manager `recovery_window_in_days` | `0` | `7` |

Multi-AZ, Performance Insights, and Enhanced Monitoring are orthogonal
— they are caller decisions and not coupled to destroy protection.
