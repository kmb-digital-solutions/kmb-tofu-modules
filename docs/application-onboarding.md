# Application Onboarding Guide

> How to add a new application root to this repository so the Singular
> Console can deploy it per-customer.

## Concept

An **application root module** under `applications/<app-slug>/` is a
complete deployable unit for one application (Spire, Traincover, etc.). It
composes shared modules from `modules/`, exposes a `console.schema.json`
that drives the Singular Console UI, and configures an S3 backend for
per-customer state.

## Files every application root must have

```
applications/<app-slug>/
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

1. **Create the directory** `applications/<app-slug>/`.

2. **Compose from shared modules** in `main.tf`. Do not redeclare what a
   shared module already does — that's why the shared modules exist.

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
   cd applications/<app-slug>
   tofu fmt -check -recursive
   tofu init -backend=false
   tofu validate
   ```

7. **Run the N-cycle test against the sandbox:**
   ```bash
   scripts/n_cycle_test.sh <app-slug> sandbox-co
   ```
   Three full apply/destroy/apply/destroy/apply cycles must succeed with
   no manual intervention. If a cycle fails, fix the module(s) — not the
   test.

8. **Open a PR.** The `module-validate.yml` CI runs the format + validate
   + variable/schema-diff checks. The N-cycle nightly catches any
   destroy regressions before they reach `main`.

9. **After merge,** tag a release: `<app-slug>/v1.0.0`. The Singular
   Console picks up the new tag via its application catalog refresh.

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
