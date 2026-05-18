# Module Development Guide

> The N-cycle test (`tofu apply → destroy → apply`, 3 times, zero manual
> intervention) is the merge gate for every application root in this
> repository. This document lists the AWS resource classes with known
> cleanup pitfalls and the patterns that defeat them.

## The `destroy_protection` variable — every module accepts it

```hcl
variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the module emits safe-but-immortal settings: deletion
    protection, no force-destroy, longer deletion windows. When false
    (non-prod), it emits cycle-friendly settings so N-cycle tests can
    apply/destroy repeatedly without manual cleanup.
  EOT
  type        = bool
  default     = false
}
```

Application roots set this from `environment == "prod"`. The N-cycle test
ONLY runs against non-prod (`destroy_protection = false`).

## Resource class playbook

### S3 buckets

```hcl
resource "aws_s3_bucket" "this" {
  bucket = "${var.customer_slug}-${var.environment}-${var.purpose}"
  force_destroy = var.destroy_protection ? false : true
}
```

* `force_destroy = true` is required for non-prod buckets — without it,
  `tofu destroy` fails if any object exists (including delete markers from
  versioning).
* Object Lock COMPLIANCE retention CANNOT be removed. Never include an
  Object-Lock COMPLIANCE bucket in a module that participates in the
  N-cycle test. Use the `hipaa-overlay` module exclusively for that.
* Versioning is fine — `force_destroy` clears versions too.

### KMS keys + aliases

```hcl
resource "aws_kms_key" "this" {
  description             = "..."
  deletion_window_in_days = var.destroy_protection ? 30 : 7
  enable_key_rotation     = true
}

# CRITICAL: alias is a separate resource so re-apply can rebind it to a
# new key without colliding with a pending-deletion key.
resource "aws_kms_alias" "this" {
  name          = "alias/${var.customer_slug}-${var.purpose}"
  target_key_id = aws_kms_key.this.key_id
}
```

* Minimum `deletion_window_in_days` is 7. Test cycles complete in
  minutes; that means a fresh `apply` after destroy creates a NEW key,
  and the old key sits in pending-deletion. This is expected and harmless
  — the alias rebinds to the new key.
* If you embed the alias *inside* `aws_kms_key`'s `policy` JSON via a
  literal name, leave it — the alias is a separate resource and the
  policy refers to it by name string, not ARN, so cycling works.

### RDS instances

```hcl
resource "aws_db_instance" "this" {
  # ... usual config ...
  deletion_protection      = var.destroy_protection
  skip_final_snapshot      = !var.destroy_protection
  apply_immediately        = !var.destroy_protection
  backup_retention_period  = var.destroy_protection ? 35 : 1
  delete_automated_backups = !var.destroy_protection
}
```

* `delete_automated_backups = true` for non-prod — otherwise old
  automated snapshots linger and block the parameter-group destroy.
* Set `apply_immediately = true` for non-prod so parameter-group changes
  don't queue a maintenance window that survives `tofu destroy`.
* Multi-AZ is a `var.multi_az` decision — orthogonal to destroy
  protection. Non-prod tests typically use single-AZ for cost.

### ECS services + clusters

```hcl
resource "aws_ecs_service" "this" {
  # ... usual config ...
  force_delete = !var.destroy_protection
}
```

* Service draining adds ~minutes per destroy; `force_delete = true` on
  non-prod skips it.
* The cluster destroys cleanly when no services reference it.

### ECR repositories

```hcl
resource "aws_ecr_repository" "this" {
  name                 = "${var.customer_slug}-${var.app}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = !var.destroy_protection
}
```

* `force_delete = true` removes the repo even if it contains images.

### Cognito user pools

```hcl
resource "aws_cognito_user_pool" "this" {
  name                = "${var.customer_slug}-${var.environment}"
  deletion_protection = var.destroy_protection ? "ACTIVE" : "INACTIVE"
}
```

* `INACTIVE` deletion protection on non-prod permits destroy.
* User pools with existing users still destroy when deletion_protection
  is INACTIVE.

### CloudWatch log groups

* Destroy cleanly. No special handling needed.
* Set `retention_in_days` from a variable — 7 for non-prod, 365 for prod.
* When the log group's KMS key (if SSE-KMS-encrypted) is in
  pending-deletion, the new log group can still be created against a
  fresh key via the alias rebinding (see KMS section above).

### NAT Gateways

* Destroy cleanly but take ~1 minute each. Single-NAT for non-prod
  shortens cycle time.

### VPC ENIs

* The most common N-cycle gotcha. A lingering Lambda-attached ENI or an
  AWS-managed ENI (from VPC endpoints, RDS, etc.) blocks subnet destroy.
* Resolution: do NOT manage Lambdas or VPC endpoints in the VPC module
  itself. Compose them in the application root so their lifecycle is
  bound to the application, not the VPC.
* VPC endpoints DO destroy cleanly when no other resources reference
  their security groups.

### Route 53 records vs hosted zones

* RECORDS destroy cleanly. Manage them in the `route53-app` module.
* HOSTED ZONES are typically pre-existing customer assets and NOT
  managed by these modules. The `route53-app` module takes a
  `hosted_zone_id` input and never creates the zone itself.

### AWS Backup

* Vault Lock COMPLIANCE cannot be destroyed. Vault Lock GOVERNANCE can
  but only by a privileged caller.
* Manage Backup ONLY in the `hipaa-overlay` module, never in the
  default-tier application stack.

## Cycle-time discipline

A clean N-cycle for an application root should complete in **under 45
minutes for 3 cycles**. If yours takes longer, look for:

* RDS without `skip_final_snapshot` — adds 3-5 min per destroy.
* ECS services without `force_delete` — adds drain time.
* NAT Gateway thrash — non-prod should use `single_nat_gateway = true`.

## Composition discipline

Application roots compose shared modules; **shared modules NEVER compose
other shared modules**. This keeps the dependency graph flat — every
module is one apply away from a usable resource, and circular references
are impossible.

If you're tempted to have `ecs-service` `module "this"` an
`observability` module — don't. Have the application root invoke both.

## Variable hygiene

* All variables typed. No `type = any`.
* All variables documented with `description`.
* All variables validated with `validation` blocks where shape matters
  (CIDR regex, slug regex, port ranges).
* No hardcoded customer-specific values, account IDs, IPs, or
  hostnames in module source. The pre-commit hook rejects 12-digit-AWS-
  account-ID literals and IPv4 literals; treat its rejections as bugs in
  your module, not in the hook.
