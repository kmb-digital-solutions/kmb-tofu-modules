# `modules/s3-bucket-secure`

Encrypted-by-default S3 bucket: SSE-KMS with a customer-managed key,
TLS-only access, KMS-on-PUT enforcement, public access locked off,
BucketOwnerEnforced ownership (ACLs disabled), and versioning on. Object
Lock COMPLIANCE is available behind a guard that requires
`destroy_protection = true`.

## Usage

```hcl
module "documents_bucket" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/s3-bucket-secure?ref=s3-bucket-secure/v1.0.0"

  customer_slug      = var.customer_slug
  environment        = var.environment
  purpose            = "documents"
  kms_key_arn        = module.kms_keys.key_arns["s3"]
  destroy_protection = var.destroy_protection

  lifecycle_rules = [
    {
      id              = "expire-90d"
      enabled         = true
      expiration_days = 90
    },
  ]
}
```

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | `string` | — | Customer slug for naming and tagging. |
| `environment` | `string` | — | One of `dev`, `staging`, `prod`. |
| `purpose` | `string` | — | Bucket purpose embedded in the name. |
| `bucket_name_override` | `string` | `null` | Escape hatch when the generated name collides globally. |
| `kms_key_arn` | `string` | — | SSE-KMS key ARN (typically from `modules/kms-key-set`). |
| `destroy_protection` | `bool` | `false` | `false` → `force_destroy = true`. |
| `enable_object_lock_compliance` | `bool` | `false` | HIPAA-overlay only. Refused unless `destroy_protection = true`. |
| `lifecycle_rules` | `list(object)` | `[]` | Opt-in S3 lifecycle rules. |
| `cors_rules` | `list(object)` | `[]` | Opt-in CORS rules. |

## Outputs

| Name | Description |
|------|-------------|
| `bucket_name` | Name of the bucket. |
| `bucket_arn` | ARN of the bucket. |
| `bucket_regional_domain_name` | Regional domain name (e.g., for CloudFront origin). |

## Pitfalls handled

See `docs/module-development.md` for the full playbook.

- **`force_destroy` semantics**: bound to `!destroy_protection`. Non-prod
  buckets clear object versions on destroy, which is what lets the N-cycle
  pass without manual emptying. Prod refuses to destroy a non-empty
  bucket.
- **Object Lock COMPLIANCE**: cannot be enabled after the bucket exists,
  and cannot be removed once on. The module refuses
  `enable_object_lock_compliance = true` unless
  `destroy_protection = true`, because the only legitimate consumer is
  the `hipaa-overlay` module — which is intentionally excluded from the
  N-cycle test.
- **Bucket name collisions**: S3 bucket names are globally unique. Rather
  than auto-suffixing to avoid collisions (unpredictable names), the
  module surfaces collisions via the `bucket_name_override` escape hatch.
- **Bucket policy ordering**: depends on the public access block so the
  policy is never briefly attached to a still-publicly-accessible bucket.

## `destroy_protection`

| | `false` (non-prod) | `true` (prod) |
|--|--|--|
| `force_destroy` | `true` | `false` |
| Object Lock allowed | rejected | allowed (HIPAA only) |
| Lifecycle | as configured | as configured |
| Versioning | on | on |
| Bucket policy | TLS-only + KMS-on-PUT | identical |
