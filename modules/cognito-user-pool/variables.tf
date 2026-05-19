variable "customer_slug" {
  description = "Customer slug used for naming and tagging. Lowercase alphanumeric and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.customer_slug))
    error_message = "customer_slug must be 3-40 chars, lowercase alphanumeric and hyphens, not start or end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment. One of dev, staging, prod."
  type        = string

  validation {
    condition     = can(regex("^(dev|staging|prod)$", var.environment))
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "application_name" {
  description = <<-EOT
    Optional logical application slug. When non-empty, the user pool name
    and the hosted-UI domain become
    `<customer_slug>-<environment>-<application_name>` so multiple
    applications in the same customer+environment don't collide on a
    single pool. `pool_name_override` still wins.

    Default empty preserves the legacy `<customer_slug>-<environment>`
    naming.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.application_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.application_name))
    error_message = "application_name must be empty or 3-32 chars lowercase alphanumeric/hyphens, not starting or ending with a hyphen."
  }
}

variable "pool_name_override" {
  description = "Override the default pool name. When null, the name defaults to <customer_slug>-<environment>."
  type        = string
  default     = null

  validation {
    condition     = var.pool_name_override == null || can(regex("^[\\w\\s+=,.@-]{1,128}$", var.pool_name_override))
    error_message = "pool_name_override must be 1-128 chars and match Cognito's allowed pool name pattern."
  }
}

variable "app_clients" {
  description = <<-EOT
    App clients to provision against the user pool. Each entry creates one
    aws_cognito_user_pool_client.

    Fields:
      name                          Client name; must be unique within the pool.
      generate_secret               When true, Cognito generates a confidential-client secret.
      allowed_oauth_flows           e.g. ["code"], ["implicit"], ["client_credentials"].
      allowed_oauth_scopes          e.g. ["openid", "email", "profile"].
      callback_urls                 OAuth callback URLs. Must be https except localhost.
      logout_urls                   OAuth logout URLs.
      explicit_auth_flows           Auth flows the client can initiate.
      access_token_validity_minutes Access token TTL in minutes.
      id_token_validity_minutes     ID token TTL in minutes.
      refresh_token_validity_days   Refresh token TTL in days.
      prevent_user_existence_errors When true (default), failed auth returns a generic error
                                    so attackers cannot enumerate valid usernames.
  EOT
  type = list(object({
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

  validation {
    condition     = length(distinct([for c in var.app_clients : c.name])) == length(var.app_clients)
    error_message = "Each app_clients[*].name must be unique."
  }

  validation {
    condition = alltrue([
      for c in var.app_clients : c.access_token_validity_minutes >= 5 && c.access_token_validity_minutes <= 1440
    ])
    error_message = "access_token_validity_minutes must be between 5 and 1440 (Cognito limit)."
  }

  validation {
    condition = alltrue([
      for c in var.app_clients : c.id_token_validity_minutes >= 5 && c.id_token_validity_minutes <= 1440
    ])
    error_message = "id_token_validity_minutes must be between 5 and 1440 (Cognito limit)."
  }

  validation {
    condition = alltrue([
      for c in var.app_clients : c.refresh_token_validity_days >= 1 && c.refresh_token_validity_days <= 3650
    ])
    error_message = "refresh_token_validity_days must be between 1 and 3650 (Cognito limit)."
  }
}

variable "mfa_configuration" {
  description = "MFA enforcement. OFF (no MFA), OPTIONAL (user-chosen), ON (mandatory — required for HIPAA-tier customers)."
  type        = string
  default     = "OFF"

  validation {
    condition     = contains(["OFF", "OPTIONAL", "ON"], var.mfa_configuration)
    error_message = "mfa_configuration must be one of: OFF, OPTIONAL, ON."
  }
}

variable "password_minimum_length" {
  description = "Minimum password length. 12+ recommended; HIPAA requires 8+ but stronger is better."
  type        = number
  default     = 12

  validation {
    condition     = var.password_minimum_length >= 6 && var.password_minimum_length <= 99
    error_message = "password_minimum_length must be between 6 and 99 (Cognito limit)."
  }
}

variable "password_require_lowercase" {
  description = "Require at least one lowercase character."
  type        = bool
  default     = true
}

variable "password_require_uppercase" {
  description = "Require at least one uppercase character."
  type        = bool
  default     = true
}

variable "password_require_numbers" {
  description = "Require at least one numeric character."
  type        = bool
  default     = true
}

variable "password_require_symbols" {
  description = "Require at least one symbol."
  type        = bool
  default     = true
}

variable "password_temporary_validity_days" {
  description = "Days admin-created temporary passwords remain valid."
  type        = number
  default     = 7

  validation {
    condition     = var.password_temporary_validity_days >= 0 && var.password_temporary_validity_days <= 365
    error_message = "password_temporary_validity_days must be between 0 and 365."
  }
}

variable "account_recovery_email" {
  description = "When true, verified email is the account recovery mechanism. Phone recovery is intentionally disabled by default for security (SIM-swap attacks)."
  type        = bool
  default     = true
}

variable "email_configuration" {
  description = <<-EOT
    Cognito email-delivery configuration.

      email_sending_account: COGNITO_DEFAULT (limited, no setup) or
                             DEVELOPER (use SES via source_arn).
      source_arn:            SES verified identity ARN. Required when
                             email_sending_account is DEVELOPER.
  EOT
  type = object({
    source_arn            = optional(string)
    email_sending_account = optional(string, "COGNITO_DEFAULT")
  })
  default = {}

  validation {
    condition     = contains(["COGNITO_DEFAULT", "DEVELOPER"], coalesce(var.email_configuration.email_sending_account, "COGNITO_DEFAULT"))
    error_message = "email_configuration.email_sending_account must be COGNITO_DEFAULT or DEVELOPER."
  }

  validation {
    condition = (
      coalesce(var.email_configuration.email_sending_account, "COGNITO_DEFAULT") == "COGNITO_DEFAULT"
      || var.email_configuration.source_arn != null
    )
    error_message = "email_configuration.source_arn is required when email_sending_account is DEVELOPER."
  }
}

variable "enable_advanced_security" {
  description = <<-EOT
    When true, enable Cognito Advanced Security (adaptive auth, compromised
    credentials detection). Advanced Security is a paid feature and requires
    a user pool domain — this module provisions a hosted-UI domain
    (<customer_slug>-<environment>) when the flag is on.
  EOT
  type        = bool
  default     = false
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the module sets deletion_protection = ACTIVE so the
    pool cannot be destroyed even if its tofu state is removed. When false
    (non-prod), deletion_protection = INACTIVE so N-cycle tests can recreate
    the pool freely.
  EOT
  type        = bool
  default     = false
}
