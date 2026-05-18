# `cognito-user-pool`

A single Cognito user pool, its app clients, and (optionally) a hosted-UI
domain for Advanced Security. Defaults are tuned for production-quality
defense in depth: strong password policy, prevented user enumeration,
verified-email-only recovery (phone disabled to defeat SIM-swap), and
HIPAA-ready MFA wiring.

## Usage

```hcl
module "user_pool" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/cognito-user-pool?ref=cognito-user-pool/v1.0.0"

  customer_slug = var.customer_slug
  environment   = var.environment

  mfa_configuration = var.environment == "prod" ? "ON" : "OFF"

  app_clients = [
    {
      name                = "web"
      generate_secret     = false
      allowed_oauth_flows = ["code"]
      allowed_oauth_scopes = ["openid", "email", "profile"]
      callback_urls = ["https://${var.app_hostname}/oauth/callback"]
      logout_urls   = ["https://${var.app_hostname}/logout"]
    },
    {
      name            = "service-to-service"
      generate_secret = true
      explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]
    },
  ]

  enable_advanced_security = var.environment == "prod"
  destroy_protection       = var.destroy_protection
}
```

## Variables

| Name                                | Type           | Default            | Description |
|-------------------------------------|----------------|--------------------|-------------|
| `customer_slug`                     | `string`       | —                  | Used for naming and tagging. |
| `environment`                       | `string`       | —                  | `dev`, `staging`, or `prod`. |
| `pool_name_override`                | `string`       | `null`             | Overrides default name `<customer_slug>-<environment>`. |
| `app_clients`                       | `list(object)` | —                  | App clients (see below). |
| `mfa_configuration`                 | `string`       | `"OFF"`            | `OFF`, `OPTIONAL`, or `ON`. |
| `password_minimum_length`           | `number`       | `12`               | Minimum length. |
| `password_require_lowercase`        | `bool`         | `true`             | Require lowercase. |
| `password_require_uppercase`        | `bool`         | `true`             | Require uppercase. |
| `password_require_numbers`          | `bool`         | `true`             | Require digits. |
| `password_require_symbols`          | `bool`         | `true`             | Require symbols. |
| `password_temporary_validity_days`  | `number`       | `7`                | Admin-created temporary password TTL. |
| `account_recovery_email`            | `bool`         | `true`             | Verified email as the recovery channel. Phone is intentionally disabled. |
| `email_configuration`               | `object`       | `{}`               | Cognito email delivery (defaults to `COGNITO_DEFAULT`). |
| `enable_advanced_security`          | `bool`         | `false`            | Paid feature; provisions a hosted-UI domain. |
| `destroy_protection`                | `bool`         | `false`            | Controls `deletion_protection`. |

### `app_clients` shape

```hcl
list(object({
  name                          = string
  generate_secret               = bool
  allowed_oauth_flows           = optional(list(string), [])
  allowed_oauth_scopes          = optional(list(string), [])
  callback_urls                 = optional(list(string), [])
  logout_urls                   = optional(list(string), [])
  explicit_auth_flows           = optional(list(string), ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"])
  access_token_validity_minutes = optional(number, 60)
  id_token_validity_minutes     = optional(number, 60)
  refresh_token_validity_days   = optional(number, 30)
  prevent_user_existence_errors = optional(bool, true)
}))
```

Client `name` must be unique within the pool. `access_token_validity_minutes`
and `id_token_validity_minutes` clamp 5–1440; `refresh_token_validity_days`
clamps 1–3650 (Cognito service limits).

## Outputs

| Name                  | Type          | Description |
|-----------------------|---------------|-------------|
| `pool_id`             | `string`      | User pool id. |
| `pool_arn`            | `string`      | User pool ARN. |
| `app_client_ids`      | `map(string)` | Client name → client id. |
| `app_client_secrets`  | `map(string)` | Client name → secret (sensitive; only present when `generate_secret = true`). |
| `pool_domain`         | `string`      | Cognito-prefix domain when advanced security is enabled, else `null`. |

## Pitfalls handled

- **N-cycle clean.** `deletion_protection` flips to `INACTIVE` on non-prod
  so `tofu destroy` succeeds even if the pool contains users.
- **No orphaned domain.** When `enable_advanced_security = true` the
  module also creates the Cognito-prefix domain that Advanced Security
  requires; both destroy together with no state surgery.
- **No user enumeration.** `prevent_user_existence_errors` defaults to
  `ENABLED`, so failed sign-ins return a generic error rather than
  leaking whether an account exists.
- **No SIM-swap path.** Account recovery defaults to verified email
  only; phone-based recovery is not configurable here. Customers needing
  it should fork the module rather than weaken the default.
- **OAuth UI gating.** `allowed_oauth_flows_user_pool_client` is set
  automatically based on whether `allowed_oauth_flows` is non-empty.
  SRP-only clients never accidentally enable the hosted UI.
- **HIPAA MFA toggle.** `mfa_configuration = "ON"` is the HIPAA setting;
  non-prod defaults to `"OFF"` for cycle simplicity. Production roots
  flip it on explicitly.

## `destroy_protection` behavior

| Setting | `deletion_protection` |
|---------|----------------------|
| `false` (non-prod) | `INACTIVE` — pool can be destroyed even with existing users. |
| `true` (prod)      | `ACTIVE` — pool cannot be destroyed until the flag is flipped back. |
