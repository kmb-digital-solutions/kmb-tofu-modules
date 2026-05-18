# `modules/kms-key-set`

Provisions a set of customer-managed KMS keys, one per logical purpose,
with rotation enabled and N-cycle-friendly deletion windows. Optionally
replicates each key into a secondary region for HIPAA-tier customers.

## Usage

```hcl
module "kms_keys" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/kms-key-set?ref=kms-key-set/v1.0.0"

  customer_slug      = var.customer_slug
  environment        = var.environment
  purposes           = ["rds", "s3", "logs", "bedrock", "secrets"]
  destroy_protection = var.destroy_protection

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }
}
```

The `aws.replica` provider alias is required even when
`enable_multi_region = false` (configuration_aliases are static). Point it
at any AWS region; nothing is created there unless the flag is on.

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | `string` | — | Customer slug for naming and tagging. |
| `environment` | `string` | — | One of `dev`, `staging`, `prod`. |
| `purposes` | `list(string)` | — | Logical purposes. One CMK + alias per entry. |
| `destroy_protection` | `bool` | `false` | `true` → 30-day deletion window; `false` → 7-day. |
| `enable_multi_region` | `bool` | `false` | Replicate each key via the `aws.replica` provider. |

## Outputs

| Name | Description |
|------|-------------|
| `key_arns` | Map of purpose to primary CMK ARN. |
| `key_ids` | Map of purpose to primary CMK key id. |
| `aliases` | Map of purpose to alias name. |
| `replica_key_arns` | Map of purpose to replica CMK ARN (empty unless multi-region). |

## Pitfalls handled

See `docs/module-development.md` for the full playbook.

- **Alias as a separate resource**: `aws_kms_alias` is its own AWS object.
  After `tofu destroy`, the CMK enters pending-deletion for
  `deletion_window_in_days`. The next `apply` creates a fresh CMK and the
  alias rebinds to it without conflict. This is the single most important
  N-cycle pattern for KMS.
- **Deletion window**: 7 days minimum on AWS. `destroy_protection = false`
  picks the minimum so non-prod accounts don't accumulate pending-deletion
  keys forever; `true` picks 30 days for prod.
- **Multi-region**: uses `aws_kms_replica_key`, not a second primary in
  another region. Key material is shared with the primary; rotation
  propagates automatically. This is the AWS-documented pattern for
  cross-region encryption parity.
- **Policy scope**: the module sets a root-only key policy. Adding service
  principals here would couple every consumer's IAM model to this module.
  Add `aws_kms_grant` (or extend the policy from the application root) on
  the consumer side instead.

## `destroy_protection`

- `false` (non-prod): `deletion_window_in_days = 7`. Cycles cleanly; old
  keys sit in pending-deletion until the window elapses, which is fine —
  the alias has already rebound to the fresh key.
- `true` (prod): `deletion_window_in_days = 30`. Recovery time for
  accidental key deletion.

Key rotation is always on, in both modes.
