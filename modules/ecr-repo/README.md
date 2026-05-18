# modules/ecr-repo

One ECR repository with immutable tags, scan-on-push, optional SSE-KMS
encryption, and a lifecycle policy that bounds tagged and untagged image
counts. Repository policy (for cross-account pull, etc.) is intentionally
left to the caller.

## Usage

```hcl
module "ecr_api" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/ecr-repo?ref=ecr-repo/v1.0.0"

  customer_slug   = var.customer_slug
  environment     = var.environment
  repository_name = "${var.customer_slug}/${var.environment}/api"
  kms_key_arn     = module.kms.image_key_arn

  destroy_protection = var.destroy_protection
}
```

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | string | — | Customer slug; lowercase alphanumeric and hyphens, 3-40 chars. |
| `environment` | string | — | One of `dev`, `staging`, `prod`. |
| `repository_name` | string | — | Full ECR repository name; lowercase, may contain slashes for namespacing. |
| `image_tag_mutability` | string | `"IMMUTABLE"` | `IMMUTABLE` or `MUTABLE`. |
| `scan_on_push` | bool | `true` | Run ECR basic scan on every push. |
| `kms_key_arn` | string | `null` | When set, repository uses SSE-KMS with this CMK. When null, SSE-AES256. |
| `untagged_image_retention_count` | number | `30` | Max untagged images retained by lifecycle policy. |
| `tagged_image_retention_count` | number | `100` | Max tagged images retained by lifecycle policy. |
| `destroy_protection` | bool | `false` | When true, `force_delete = false` on the repo. |

## Outputs

| Name | Description |
|------|-------------|
| `repository_url` | ECR repository URL. |
| `repository_arn` | ECR repository ARN. |
| `repository_name` | ECR repository name. |

## Pitfalls handled

- **`force_delete = !var.destroy_protection`.** Non-prod repositories
  destroy even when they contain images, so the N-cycle test can rebuild
  the repository without manual pruning. Prod repositories fail loudly
  on destroy of a non-empty repo.
- **No default repository policy.** Cross-account replication, pull
  grants, and public access controls are explicitly out of scope for
  this module. Add them in the application root.
- **Lifecycle policy uses `imageCountMoreThan`,** which is deterministic
  and idempotent. Time-based policies are avoided because they create
  drift between consecutive plans.
- **SSE-KMS is opt-in.** The default AES-256 encryption is sufficient
  for most repositories; opt into SSE-KMS only when a customer KMS-CMK
  audit trail is required (HIPAA, FedRAMP).

## `destroy_protection` behavior

- `false` (default for non-prod): `force_delete = true`. `tofu destroy`
  removes the repository even if it contains images.
- `true` (prod): `force_delete = false`. Operators must delete images
  out-of-band before destroying the repository, ensuring no
  accidental loss of production image history.
