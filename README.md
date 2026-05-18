# kmb-tofu-modules

Shared OpenTofu modules for the Singular Console control plane.

This repository is the **single source of truth for infrastructure
building blocks** across every Singular product. It is PUBLIC and holds
only customer-agnostic, parameterized modules — no application-specific
composition, no customer-specific values, no account IDs. Application
roots that compose these modules live in each product's own (private)
repository and reference modules here via remote git URLs.

## Repository layout

```
.
├── modules/                     Shared building blocks. Each module is
│   ├── vpc/                       independently versioned via git tags and
│   ├── ecs-cluster/               consumed by application roots via
│   ├── ecs-service/                 git::https://...?ref=<module>/vX.Y.Z
│   ├── ecr-repo/
│   ├── rds-postgres/
│   ├── kms-key-set/
│   ├── s3-bucket-secure/
│   ├── route53-app/
│   ├── cognito-user-pool/
│   ├── observability/
│   └── hipaa-overlay/           Conditional overlay for HIPAA-tier customers.
│
├── scripts/
│   ├── n_cycle_test.sh          Generic acceptance harness — accepts
│   │                              APPLICATION_PATH for any external root.
│   ├── validate_all.sh          fmt + init + validate across modules/.
│   ├── lint_no_literals.sh      Refuse sensitive literals in module source.
│   └── publish_module.sh        Tag-and-push automation for a module version.
│
├── docs/
│   ├── module-development.md    The pitfall guide — read before authoring.
│   ├── bootstrap-sandbox-account.md
│   └── application-onboarding.md
│
└── .github/workflows/
    ├── module-validate.yml      PR gate: `tofu fmt`, `tofu validate`, tflint,
    │                              and the sensitive-literal lint.
    └── n-cycle-test.yml         Manual workflow — typically invoked from a
                                  product repo's own CI with APPLICATION_PATH.
```

**Application roots do NOT live in this repository.** This repo is
PUBLIC and the architectural detail of how Spire/Traincover compose
infrastructure is proprietary. Application roots live in each
application's own private repository at `<repo>/infrastructure-modular/`
and reference modules here via remote git URLs:

```hcl
module "vpc" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/vpc?ref=vpc/v1.0.0"
  # ...
}
```

Current consuming application roots (as of Sprint 4):

| Application | Root location |
|-------------|---------------|
| Spire | `Singular-Systems/Spire/kmb-SOAP-be/infrastructure-modular/` |
| Traincover | `Singular-Systems/ATS/traincover/infrastructure-modular/` |

See `docs/application-onboarding.md` for the full onboarding contract.

## OpenTofu, not Terraform

Use the `tofu` CLI throughout. Module sources and provider versions are
pinned to the OpenTofu registry; HCL syntax is identical, but the binary
differs. Do not invoke `terraform` against this repository — `tofu fmt`,
`tofu init`, `tofu validate`, `tofu plan`, `tofu apply`, `tofu destroy`.

## Module versioning

Every module is versioned independently via repository-wide git tags of the
form `<module>/vX.Y.Z` (e.g. `vpc/v1.2.0`). Application roots consume a
specific tag:

```hcl
module "vpc" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/vpc?ref=vpc/v1.2.0"

  customer_slug      = var.customer_slug
  environment        = var.environment
  cidr_block         = "10.0.0.0/16"
  availability_zones = 2
  enable_nat_gateway = true
  single_nat_gateway = !var.destroy_protection
  destroy_protection = var.destroy_protection
}
```

Semver discipline:

* **MAJOR** — breaking variable removal, output rename, or change in resource
  identity that forces replacement of existing infrastructure.
* **MINOR** — new variables with safe defaults, new outputs, new optional
  resources behind a feature flag.
* **PATCH** — internal refactor, documentation, formatting. Behavior
  identical for every existing variable combination.

Never mutate a tag once pushed. If a tag was published in error, publish a
new patch tag with the fix and document the bad tag in `docs/yanked-tags.md`.

## N-cycle test — the merge gate

Every application root module MUST pass 3 full cycles of
`tofu apply → tofu destroy → tofu apply → tofu destroy → tofu apply` in a
sandbox customer account with **no manual intervention** between cycles. No
state surgery, no orphan resources, no `prevent_destroy` flips, no waiting
for KMS deletion windows.

The harness lives at `scripts/n_cycle_test.sh <app> <sandbox_customer_slug>`.
Nightly CI runs it against a dedicated sandbox account (see
`docs/bootstrap-sandbox-account.md`). A failing cycle blocks merges to
`main`.

Shared modules under `modules/` are exercised transitively by their consuming
application roots. They do not have stand-alone N-cycle tests — but every
shared module MUST be authored such that the application roots it composes
PASS the cycle.

The `hipaa-overlay` module is the documented exception: Vault Lock COMPLIANCE
and Object Lock COMPLIANCE cannot be cleaned within the cycle window. It is
NEVER part of an N-cycle test and is composed only when `destroy_protection
= true`.

## Authoring a module

1. Read `docs/module-development.md` — it lists every AWS resource class with
   a known cleanup pitfall and the pattern that defeats it.
2. Every module accepts a `destroy_protection` bool (default `false`). When
   `false`, the module emits non-prod-friendly settings (force_destroy on
   S3, skip_final_snapshot on RDS, deletion_window_in_days=7 on KMS, etc.).
   When `true`, it emits the safe variants.
3. Module variables MUST be parameterized — no hardcoded account IDs, IP
   addresses, customer slugs, or environment names. The pre-commit hook and
   the CI lint enforce this.
4. Every module ships its own `README.md`, `variables.tf`, `outputs.tf`,
   `main.tf`, and `versions.tf`. Pin provider versions in `versions.tf`.
5. After your module is N-cycle-clean in a consuming application root, tag
   a new version: `scripts/publish_module.sh modules/<name> v1.0.0`.

## Public visibility

This repository is **public**. Module code is visible to the world. Three
rules follow:

* **No secrets** — not in defaults, not in examples, not in README snippets.
* **No customer identifiers** — slugs, names, internal hostnames, S3 bucket
  names that include a customer slug as a literal. Everything goes through
  variables.
* **No infrastructure account IDs** — neither Singular's nor any customer's.
  The pre-commit hook rejects 12-digit-account-ID literals in module source.

## Operator quick-start

```bash
# Validate a single module
cd modules/vpc
tofu fmt -check -recursive
tofu init -backend=false
tofu validate

# Validate the whole repository
scripts/validate_all.sh

# Run the N-cycle test for an application
scripts/n_cycle_test.sh traincover sandbox-co
```
