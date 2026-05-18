# Changelog

All notable changes to `kmb-tofu-modules` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Each module is versioned independently via repo-wide git tags of the form
`<module>/vX.Y.Z`.

## [Unreleased]

### Added — Sprint 3 bootstrap (2026-05-18)

**You can now compose Singular's infrastructure from reusable OpenTofu modules.** This repository becomes the single source of truth for IaC across every Singular product.

- **Repository scaffold** — directory layout for `modules/`, `applications/`, `scripts/`, `docs/`, and CI workflows. README explains the OpenTofu-only policy, semver tagging convention, and the public-visibility rules.
- **Module development guide** at `docs/module-development.md` enumerates AWS resource classes with known cleanup pitfalls (S3 versioning, KMS deletion windows, RDS final snapshots, ECS service draining, Cognito deletion protection, lingering ENIs, AWS Backup vault locks) and the patterns that defeat each one. Every module accepts a `destroy_protection` variable that flips between cycle-friendly and prod-safe settings.
- **N-cycle test harness** at `scripts/n_cycle_test.sh` runs the acceptance test: `tofu apply → destroy → apply → destroy → apply` (3 cycles by default) against the sandbox AWS account with no manual intervention. Includes post-apply plan-verify (catches non-idempotency) and post-final-destroy orphan-sweep (catches incomplete cleanup).
- **Repository-wide validation** at `scripts/validate_all.sh` runs `tofu fmt`, `tofu init -backend=false`, and `tofu validate` against every module and application root. Local equivalent of the CI gate.
- **Sensitive-literal lint** at `scripts/lint_no_literals.sh` rejects 12-digit AWS account IDs and public-IPv4 literals in module source. Modules must parameterize every customer-specific value; the public-repo policy depends on it.
- **CI workflows** under `.github/workflows/`:
  - `module-validate.yml` runs on every PR and push to main: format, validate, tflint, sensitive-literal lint, and a `variables.tf` ↔ `console.schema.json` diff that fails on any variable-surface mismatch.
  - `n-cycle-test.yml` runs nightly at 02:00 UTC against the sandbox account via OIDC-assumed IAM role; `workflow_dispatch` available for ad-hoc runs.
- **Sandbox bootstrap guide** at `docs/bootstrap-sandbox-account.md` walks operators through provisioning the dedicated sandbox account, configuring GitHub Actions OIDC trust, and setting the required repository secrets.
- **Application onboarding guide** at `docs/application-onboarding.md` documents how to add a new `applications/<slug>/` root that the Singular Console can deploy per-customer, including the `console.schema.json` format and the backend-config injection contract.

### Modules — 11 added in this commit

All eleven shared modules land in a single commit. Each is independently usable from an application root via a `git::` source pin (tags follow next).

**Foundational**

- **`modules/vpc`** — 3-tier VPC across N AZs (public + private + isolated), IGW, NAT Gateways (single-NAT for non-prod cost), default-deny security group, S3/DynamoDB gateway endpoints + arbitrary interface endpoints. The `single_nat_gateway` toggle is the cycle-time win for the N-cycle test.
- **`modules/kms-key-set`** — A list of CMKs by purpose (`["rds", "s3", "logs", "bedrock", "secrets"]`), each with a separate `aws_kms_alias` resource so re-apply can rebind to a fresh key while the prior key sits in its mandatory pending-deletion window. Optional `enable_multi_region` replicates to us-west-2 via `aws_kms_replica_key` (for HIPAA-tier DR).
- **`modules/s3-bucket-secure`** — Bucket with BPA all-on, SSE-KMS, TLS-only policy, versioning, lifecycle, optional Object Lock COMPLIANCE. A `precondition` refuses Object Lock unless `destroy_protection = true` — the only legitimate consumer is `hipaa-overlay`.

**Workload runtime**

- **`modules/ecs-cluster`** — Fargate cluster with Fargate-Spot capacity provider and optional Container Insights.
- **`modules/ecs-service`** — ECS service + task definition + IAM execution/task role split + CloudWatch log group + target-tracking autoscaling. `deployment_circuit_breaker` rolls back failed deploys automatically. `force_delete = true` on non-prod skips drain wait. `ignore_changes = [desired_count]` so autoscaling owns the dial.
- **`modules/ecr-repo`** — ECR with scan-on-push, IMMUTABLE tags by default, lifecycle policy keeps last 30 untagged + last 100 tagged, `force_delete` gated on `destroy_protection`.
- **`modules/rds-postgres`** — Postgres 16 with parameter group enforcing TLS, optional Multi-AZ, optional Performance Insights, Master password auto-generated and stored in Secrets Manager (CMK-encrypted), `iam_database_authentication_enabled = true` by default. `skip_final_snapshot`, `delete_automated_backups`, and `apply_immediately` all flip on `destroy_protection` so N-cycle destroys complete cleanly.

**Supporting**

- **`modules/route53-app`** — DNS records under an EXISTING hosted zone (caller provides `hosted_zone_id`; module never creates zones). `for_each` keyed by `${name}|${type}` so reordering inputs doesn't force replacement. Validations refuse alias + literal rrdata mix and duplicate `(name, type)` pairs.
- **`modules/cognito-user-pool`** — User pool + app clients (multiple per pool), software-token MFA, 12-char min password policy with all four classes, email-only recovery hard-locked (SIM-swap mitigation), advanced security gated by variable (costs money). `deletion_protection = INACTIVE` on non-prod to permit destroy with existing users.
- **`modules/observability`** — CloudWatch log groups with optional CMK encryption and per-group retention, metric alarms with symmetric `alarm_actions` + `ok_actions` routing (dashboards see recoveries, not just alarms), optional module-managed SNS topic for alarms without an explicit destination.

**Compliance overlay (NOT N-cycle eligible)**

- **`modules/hipaa-overlay`** — CloudTrail organization trail, GuardDuty, Macie, Security Hub (with AWS Foundational Best Practices + CIS standards), Inspector for ECR/EC2/Lambda, AWS Config with the AWS-published HIPAA Security conformance pack (committed as `conformance-packs/hipaa-security.yaml` so the rule set is pinned to the module tag), AWS Backup vault with **Vault Lock COMPLIANCE** + cross-region copy. The lock has a 72-hour grace window (`changeable_for_days = 3`) for operator abort — after that, AWS Support cannot remove it. The module REFUSES to deploy unless `destroy_protection = true`; application roots compose it conditionally on `var.hipaa_enabled && var.destroy_protection`.

### Module conventions enforced across all 11

- Every module accepts `destroy_protection bool` (default `false`) and flips internal settings between cycle-friendly and prod-safe based on it.
- Every resource is tagged with `customer_slug`, `environment`, `module`, `managed_by = "tofu"` via a `local.common_tags` map merged per-resource.
- All variables typed, documented, and validation-gated where shape matters (CIDR, ARN, slug regex, port range, enum membership).
- Zero hardcoded customer slugs, account IDs, public IPs, or hostnames — enforced by `scripts/lint_no_literals.sh` in CI.
- Each module is independently `tofu init -backend=false && tofu validate` clean.

### Notes

- All 11 modules validate cleanly (`./scripts/validate_all.sh`). The N-cycle test against a real sandbox account is the actual merge gate; that test runs only when application roots (Sprint 4) compose the modules. Sprint 3 ships the leaves; Sprint 4 ships the roots that exercise them.
- The `hipaa-overlay` module is the documented exception to the N-cycle rule — Vault Lock COMPLIANCE and Object Lock COMPLIANCE cannot be cleaned within the cycle window.
- No module composes another module. Application roots are the only composers.

[Unreleased]: https://github.com/kmb-digital-solutions/kmb-tofu-modules/compare/main...HEAD
