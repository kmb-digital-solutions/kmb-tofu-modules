# Application Onboarding Guide

> How to author an application root module that consumes the shared
> modules in this repository, so the Singular Console can deploy it
> per-customer.

## Concept

An **application root module** is a complete deployable unit for one
application (Spire, Traincover, etc.). It composes shared modules from
this repo via remote git sources, exposes a `console.schema.json` that
drives the Singular Console UI, and configures an S3 backend for
per-customer state.

**Application roots live in each application's own (private) repository,
NOT in this public modules repo.** This repository holds only the
shared, customer-agnostic modules. Application roots reference modules
here via:

```hcl
source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/<name>?ref=<module>/vX.Y.Z"
```

Convention for the path within an application's own repo:

| Application | Root path |
|-------------|-----------|
| Spire | `kmb-SOAP-be/infrastructure-modular/` |
| Traincover | `infrastructure-modular/` |
| (future apps) | `infrastructure-modular/` at the repo root or alongside an existing `infrastructure/` directory during migration |

The `-modular` suffix is a transitional naming convention used while a
legacy `infrastructure/` directory exists in the same repo. After the
live-migration step (Singular Console requirements doc, I4.3/I4.4), the
legacy directory is archived and `infrastructure-modular` becomes
`infrastructure`.

## Files every application root must have

```
<product-repo>/infrastructure-modular/
├── main.tf              # Compose modules; declare any app-specific resources.
├── variables.tf         # Input surface — must match console.schema.json.
├── outputs.tf           # ARNs, URLs, etc. that the console exposes.
├── versions.tf          # OpenTofu + provider version pins.
├── backend.tf           # Partial S3 backend; console injects bucket/key/lock at init.
├── console.schema.json  # JSON Schema 2020-12 describing the variable surface.
└── README.md            # What this application is, what it provisions.
```

### `backend.tf` shape

Backend config is partial — the Console fills it in via `-backend-config`
flags at `tofu init` time so each customer × environment gets its own
state file.

```hcl
terraform {
  backend "s3" {
    # All fields injected by the Singular Console:
    #   bucket         = <per-customer state bucket>
    #   key            = customers/<slug>/<app>/<env>/terraform.tfstate
    #   region         = us-east-1
    #   dynamodb_table = singular-tfstate-locks
    #   encrypt        = true
    #   kms_key_id     = alias/singular-tfstate-key
  }
}
```

Do not hardcode any of these in `backend.tf` — leaving them empty is how
OpenTofu accepts the dynamic injection.

### `console.schema.json` shape

The console renders a form from this schema and validates submitted values
against it. The full schema spec is in
`docs/requirements/2026-05-18-singular-console-mvp.md` Technical Spec
section. Minimum example:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Traincover Application",
  "type": "object",
  "required": ["customer_slug", "environment", "aws_account_id"],
  "properties": {
    "customer_slug": {
      "type": "string",
      "pattern": "^[a-z0-9-]+$",
      "x-console": {"locked": true, "hint": "Set by console from customer record"}
    },
    "environment": {
      "type": "string",
      "enum": ["dev", "staging", "prod"],
      "x-console": {"locked": true, "hint": "Set by console from deployment"}
    },
    "aws_account_id": {
      "type": "string",
      "pattern": "^[0-9]{12}$",
      "x-console": {"locked": true, "hint": "Set by console from account record"}
    },
    "instance_class": {
      "type": "string",
      "default": "db.t4g.medium",
      "x-console": {"hint": "RDS instance class for the app database"}
    }
  }
}
```

Every variable in `variables.tf` must have a matching property in
`console.schema.json`, and vice versa. The `module-validate.yml` CI step
diffs the two and fails on mismatch.

## Onboarding sequence

1. **Create the directory** at `<product-repo>/infrastructure-modular/`.
   Add a sibling `.gitignore` ignoring `.terraform/`, `*.tfstate`,
   `*.tfvars`, `*.tfplan`, `.terraform.lock.hcl`.

2. **Compose from shared modules** in `main.tf` via remote git sources:

   ```hcl
   source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/<name>?ref=<module>/vX.Y.Z"
   ```

   Do not redeclare what a shared module already does — that's why the
   shared modules exist. Modules pin to specific semver tags; never
   reference `?ref=main` from a production deployment.

3. **Wire `destroy_protection`** consistently. Every shared module accepts
   it; pass `var.destroy_protection` through from the application root's
   variable. Application root sets it from `environment == "prod"`.

4. **Wire `hipaa_enabled`** if the application can run in Clinical tier.
   Compose `modules/hipaa-overlay` conditionally:

   ```hcl
   module "hipaa_overlay" {
     count  = var.hipaa_enabled && var.destroy_protection ? 1 : 0
     source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/hipaa-overlay?ref=hipaa-overlay/v1.0.0"
     # ...
   }
   ```

5. **Write `console.schema.json`** matching the variable surface.

6. **Validate locally:**
   ```bash
   cd <product-repo>/infrastructure-modular
   tofu fmt -check -recursive
   tofu init -backend=false   # fetches modules from this repo via git
   tofu validate
   ```

7. **Run the N-cycle test against the sandbox**, invoking the harness
   from a local clone of `kmb-tofu-modules`:

   ```bash
   cd <wherever-you-cloned>/kmb-tofu-modules
   APPLICATION_PATH=<product-repo>/infrastructure-modular \
   SANDBOX_AWS_ACCOUNT_ID=<id> \
     ./scripts/n_cycle_test.sh <app-slug> sandbox-co
   ```

   Three full apply/destroy/apply/destroy/apply cycles must succeed with
   no manual intervention. If a cycle fails, fix the module(s) — not the
   test.

8. **Open a PR in the product repo.** The product repo's own CI runs
   `tofu fmt`, `tofu validate`, and the variable/schema-diff check
   against `infrastructure-modular/`. The N-cycle test runs nightly via
   a product-repo workflow that checks out kmb-tofu-modules and invokes
   the harness with `APPLICATION_PATH=./infrastructure-modular`.

9. **After merge,** tag a release in the product repo. The Singular
   Console picks up the new commit/tag via its application catalog
   refresh.

10. **Register in Singular Console** (Sprint 5 task B5.1):
    ```http
    POST /api/v1/applications
    Content-Type: application/json
    {
      "slug": "<app-slug>",
      "repo_url": "https://github.com/kmb-digital-solutions/kmb-tofu-modules",
      "root_path": "applications/<app-slug>",
      "default_module_version": "<app-slug>/v1.0.0"
    }
    ```

## Naming conventions

* Application slug: `^[a-z0-9-]{2,32}$`. Stable for the application's
  lifetime — it appears in S3 keys, AWS resource tags, and the console
  URL. Renaming is a structural migration, not a casual change.
* Resource names: `<customer_slug>-<environment>-<purpose>` so a grep in
  the AWS console scopes by customer immediately.
