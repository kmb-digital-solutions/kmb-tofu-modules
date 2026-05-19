# cognito-user-pool
#
# Manages a single Cognito user pool, its app clients, and (when advanced
# security is enabled) its hosted-UI domain. Designed to N-cycle clean:
# deletion_protection follows var.destroy_protection, the optional hosted-
# UI domain destroys cleanly with the pool, and existing users do not
# block destroy when deletion_protection is INACTIVE.

locals {
  # `<customer>-<env>[-<app>]`. App-aware namespacing kicks in when the
  # caller passes a non-empty application_name. pool_name_override always wins.
  name_prefix_base = var.application_name == "" ? "${var.customer_slug}-${var.environment}" : "${var.customer_slug}-${var.environment}-${var.application_name}"

  pool_name = coalesce(var.pool_name_override, local.name_prefix_base)

  app_clients_by_name = {
    for c in var.app_clients : c.name => c
  }

  common_tags = merge(
    {
      customer_slug = var.customer_slug
      environment   = var.environment
      module        = "cognito-user-pool"
      managed_by    = "tofu"
    },
    var.application_name == "" ? {} : { application = var.application_name },
  )

  # Account recovery: verified email only. Phone is intentionally excluded
  # to defeat SIM-swap takeover paths. If a customer needs phone recovery
  # they should fork this module — never silently accept the weaker config.
  account_recovery_mechanisms = var.account_recovery_email ? [
    {
      name     = "verified_email"
      priority = 1
    }
  ] : []
}

resource "aws_cognito_user_pool" "this" {
  name = local.pool_name

  deletion_protection = var.destroy_protection ? "ACTIVE" : "INACTIVE"

  mfa_configuration = var.mfa_configuration

  password_policy {
    minimum_length                   = var.password_minimum_length
    require_lowercase                = var.password_require_lowercase
    require_uppercase                = var.password_require_uppercase
    require_numbers                  = var.password_require_numbers
    require_symbols                  = var.password_require_symbols
    temporary_password_validity_days = var.password_temporary_validity_days
  }

  # SMS MFA configuration is intentionally omitted. When mfa_configuration
  # is ON/OPTIONAL we use software-token MFA only — SMS MFA requires
  # provisioning an IAM role for SNS publish, which would push the
  # blast-radius of this module beyond a single resource class. Customers
  # needing SMS MFA should layer it via a sibling module from the
  # application root.
  dynamic "software_token_mfa_configuration" {
    for_each = var.mfa_configuration == "OFF" ? [] : [1]
    content {
      enabled = true
    }
  }

  dynamic "account_recovery_setting" {
    for_each = length(local.account_recovery_mechanisms) == 0 ? [] : [1]
    content {
      dynamic "recovery_mechanism" {
        for_each = local.account_recovery_mechanisms
        content {
          name     = recovery_mechanism.value.name
          priority = recovery_mechanism.value.priority
        }
      }
    }
  }

  dynamic "email_configuration" {
    for_each = [var.email_configuration]
    content {
      source_arn            = email_configuration.value.source_arn
      email_sending_account = coalesce(email_configuration.value.email_sending_account, "COGNITO_DEFAULT")
    }
  }

  dynamic "user_pool_add_ons" {
    for_each = var.enable_advanced_security ? [1] : []
    content {
      advanced_security_mode = "ENFORCED"
    }
  }

  tags = local.common_tags
}

resource "aws_cognito_user_pool_client" "this" {
  for_each = local.app_clients_by_name

  name         = each.value.name
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = each.value.generate_secret

  # OAuth wiring. allowed_oauth_flows_user_pool_client must be true any
  # time we surface OAuth flows/scopes; gate it on flows being non-empty
  # so SRP-only clients don't accidentally enable the hosted UI.
  allowed_oauth_flows_user_pool_client = length(each.value.allowed_oauth_flows) > 0
  allowed_oauth_flows                  = each.value.allowed_oauth_flows
  allowed_oauth_scopes                 = each.value.allowed_oauth_scopes
  callback_urls                        = each.value.callback_urls
  logout_urls                          = each.value.logout_urls

  explicit_auth_flows = each.value.explicit_auth_flows

  # Token validity. Cognito expects the units in a separate block; we
  # always emit minutes/minutes/days to match the variable contract.
  access_token_validity  = each.value.access_token_validity_minutes
  id_token_validity      = each.value.id_token_validity_minutes
  refresh_token_validity = each.value.refresh_token_validity_days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = each.value.prevent_user_existence_errors ? "ENABLED" : "LEGACY"
}

# Advanced Security requires the pool to have a hosted-UI domain. We
# provision a short, deterministic one: <customer_slug>-<environment>.
# Cognito-prefix domains destroy cleanly when the parent pool destroys.
resource "aws_cognito_user_pool_domain" "this" {
  count = var.enable_advanced_security ? 1 : 0

  domain       = local.name_prefix_base
  user_pool_id = aws_cognito_user_pool.this.id
}
