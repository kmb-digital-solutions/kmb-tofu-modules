# `modules/hipaa-overlay`

HIPAA Security Rule technical safeguards as a composable overlay: AWS
Backup with Vault Lock COMPLIANCE, CloudTrail organization trail, GuardDuty,
Macie, Security Hub, Inspector v2, AWS Config + HIPAA conformance pack.

---

## WARNING — IRREVERSIBLE RETENTION

> **THIS MODULE DEPLOYS IRREVERSIBLE RETENTION.**
>
> **AWS Backup Vault Lock in COMPLIANCE mode CANNOT be deleted until the
> lock duration expires.** Even AWS Support cannot bypass it. Vaults
> created by this module sit in an initial 3-day grace window
> (`changeable_for_days = 3`); after that window passes, the lock becomes
> permanent for the configured `min_retention_days` plus the lifetime of
> every recovery point in the vault.
>
> **S3 Object-Lock buckets composed alongside this overlay cannot be
> cleared until the longest object retention expires** (potentially 7
> years for HIPAA-bearing data).
>
> **Compose this module only when you are prepared to keep the resources
> running for the configured lock duration.** The repository's N-cycle
> test never composes this module — it is the documented exception (see
> root `README.md` and `docs/module-development.md`).

---

## Usage

```hcl
module "hipaa" {
  count  = var.hipaa_enabled && var.destroy_protection ? 1 : 0
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/hipaa-overlay?ref=hipaa-overlay/v1.0.0"

  customer_slug       = var.customer_slug
  environment         = var.environment
  aws_account_id      = var.aws_account_id
  security_account_id = var.security_account_id

  destroy_protection = var.destroy_protection  # must be true; module refuses otherwise

  regions              = ["us-east-1"]
  backup_kms_key_arn   = module.kms_key_set.key_arns_by_purpose["backup"]
  cloudtrail_s3_bucket = var.cloudtrail_bucket_in_security_account
  s3_logs_bucket_arn   = var.central_logs_bucket_arn

  s3_data_event_buckets = [
    module.documents_bucket.arn,  # PHI-bearing
  ]

  backup_plan_rules = [
    {
      rule_name                         = "daily-7y"
      schedule_expression               = "cron(0 5 ? * * *)"
      start_window_minutes              = 60
      completion_window_minutes         = 360
      target_vault_name                 = "${var.customer_slug}-prod-compliance-vault"
      delete_after_days                 = 2555  # 7 years
      lifecycle_cold_storage_after_days = 90
    },
  ]
}
```

The `count = var.hipaa_enabled && var.destroy_protection ? 1 : 0` guard is
**mandatory**. The module's own `destroy_protection` variable has a
`validation` block that refuses any value other than `true`, but the outer
guard prevents accidental composition into a non-HIPAA or non-prod
environment.

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | `string` | — | Customer slug used for naming/tagging. |
| `environment` | `string` | — | Must be `prod`. Validated. |
| `aws_account_id` | `string` | — | 12-digit account ID where the overlay deploys. |
| `security_account_id` | `string` | — | 12-digit security account ID. |
| `destroy_protection` | `bool` | `false` | Must be `true`. Module refuses otherwise. |
| `regions` | `list(string)` | `["us-east-1"]` | Regions for regional services. |
| `backup_kms_key_arn` | `string` | — | KMS key ARN for the Backup vault. |
| `s3_logs_bucket_arn` | `string` | `null` | Optional centralized logs bucket ARN. |
| `cloudtrail_s3_bucket` | `string` | — | CloudTrail destination bucket name (in security account). |
| `s3_data_event_buckets` | `list(string)` | `[]` | PHI-bearing S3 bucket ARNs for CloudTrail data events. |
| `enable_guardduty` | `bool` | `true` | Enable GuardDuty detector. |
| `guardduty_master_account_id` | `string` | `null` | GuardDuty master account; defaults to `security_account_id`. |
| `enable_macie` | `bool` | `true` | Enable Macie. |
| `enable_security_hub` | `bool` | `true` | Enable Security Hub + FSBP/CIS standards. |
| `enable_inspector` | `bool` | `true` | Enable Inspector v2 for ECR/EC2/Lambda. |
| `enable_config` | `bool` | `true` | Enable AWS Config + HIPAA conformance pack. |
| `backup_plan_rules` | `list(object)` | `[]` | Backup plan rules (see object shape in `variables.tf`). |

## Outputs

| Name | Description |
|------|-------------|
| `backup_vault_arn` | ARN of the COMPLIANCE-locked Backup vault. |
| `backup_vault_name` | Name of the vault. |
| `backup_plan_id` | Backup plan ID (null if no rules supplied). |
| `backup_plan_arn` | Backup plan ARN. |
| `backup_iam_role_arn` | IAM role ARN for `aws_backup_selection` wiring. |
| `cloudtrail_arn` | CloudTrail trail ARN. |
| `cloudtrail_name` | CloudTrail trail name. |
| `guardduty_detector_id` | GuardDuty detector ID (null if disabled). |
| `macie_account_id` | Macie account resource ID (null if disabled). |
| `security_hub_account_id` | Security Hub subscription resource ID (null if disabled). |
| `inspector_status` | `"enabled"` or `"disabled"`. |
| `config_recorder_name` | Config recorder name (null if disabled). |

## Cross-account requirements

The `security_account_id` (the central security account) must already
have, before this module applies cleanly:

- **S3 bucket for CloudTrail.** The bucket named in `cloudtrail_s3_bucket`
  must exist in the security account with a bucket policy that allows
  `s3:PutObject` from this account's CloudTrail principal
  (`cloudtrail.amazonaws.com` with `aws:SourceAccount = aws_account_id`).
  When `s3_logs_bucket_arn` is supplied, that bucket must analogously
  allow `config.amazonaws.com` from this account.
- **GuardDuty cross-account wiring.** Either (a) the security account is
  configured as the GuardDuty delegated administrator at the
  Organizations level — in which case every member account's detector is
  auto-enrolled — or (b) the security account issues
  `aws_guardduty_member` invitations and the customer account uses
  `aws_guardduty_invite_accepter` (composed by the application root, not
  this module).
- **Security Hub aggregation.** The security account must enable Security
  Hub finding aggregation; this module simply enables Security Hub
  locally.
- **AWS Backup cross-region copy destination.** When any
  `backup_plan_rules[*].copy_to_destination_vault_arn` is set, the
  destination vault must already exist in the destination region/account
  with a vault policy allowing copy-in from this account.

These are deliberately external to the module so the security account
remains the single owner of cross-account trust policies.

## Why this module is exempt from N-cycle testing

The N-cycle test (`apply → destroy → apply`, three times, zero manual
intervention) is the merge gate for every other module in this
repository. This module is the documented exception:

- **`aws_backup_vault_lock_configuration` in COMPLIANCE mode** cannot be
  removed until `min_retention_days` has elapsed AND every recovery point
  has expired. There is no force-destroy. AWS Support cannot help.
- **The HIPAA conformance pack via `aws_config_conformance_pack`** can be
  destroyed cleanly, but spinning it up and down repeatedly produces
  spurious findings noise in the security account's aggregation.
- **Object Lock COMPLIANCE buckets** (composed separately via
  `s3-bucket-secure` with Object Lock enabled when `hipaa_enabled = true`)
  cannot be cleared until every object's retention expires.

Composition discipline:

- Application roots gate this module with
  `count = var.hipaa_enabled && var.destroy_protection ? 1 : 0`.
- The module's own `destroy_protection` variable has a `validation` block
  that refuses any value other than `true`, providing a second layer of
  defense.
- The repository's `n-cycle-test.yml` workflow runs only application
  slugs (not module names) and does not exercise HIPAA-tier
  configurations.

## Cost note

Approximate monthly cost on a low-traffic Traincover-sized HIPAA tenant,
us-east-1, May 2026 pricing:

| Service | Estimate | Notes |
|---|---|---|
| AWS Config | $50–$120 | Conformance pack rules evaluated continuously. |
| GuardDuty | $30–$80 | Scales with VPC flow + CloudTrail event volume. |
| Macie | $20–$60 | Scales with S3 bucket inventory + sampling. |
| Security Hub | $5–$15 | Per-check pricing across FSBP + CIS standards. |
| Inspector v2 | $5–$15 | ECR + Lambda continuous scanning. |
| CloudTrail (mgmt) | Free | First copy of management events. |
| CloudTrail data events | $5–$25 | Per million events; scales with PHI S3 traffic. |
| AWS Backup storage | Variable | Pays per GB-month per recovery point. |

**Floor: roughly $100–$300/month** before backup storage. Backup storage
dominates over long retention windows — 7 years of daily snapshots at
hundreds of GB/day adds up. Budget accordingly.

## Pitfalls handled

- **Vault Lock grace window.** `changeable_for_days = 3` lets an operator
  abort the lock within 72 hours of initial apply. After that, the lock
  is permanent. Cycle this module ONLY in non-production AWS accounts
  that you are prepared to write off.
- **Backup retention math.** `min_retention_days` is auto-computed from
  the longest `delete_after_days` plus a 30-day buffer, never below 7
  days. This prevents a misconfigured plan from creating recovery points
  that violate the lock floor.
- **Config bucket policy.** This module does NOT create the destination
  bucket — it's owned by the security account. The module's IAM policy
  for the Config role grants `s3:PutObject` only; the bucket-side policy
  is the security account's responsibility.
- **KMS access.** The Backup service role has an inline policy granting
  the standard KMS verbs against `backup_kms_key_arn`. The
  key policy on the kms-key-set side must grant `backup.amazonaws.com`
  as well — verify both sides before applying.
