variable "customer_slug" {
  description = "Customer slug used for tagging. Lowercase alphanumeric and hyphens only."
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

variable "service_name" {
  description = "Service name used in log group paths and the default SNS topic name. Lowercase alphanumeric and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.service_name))
    error_message = "service_name must be 3-40 chars, lowercase alphanumeric and hyphens, not start or end with a hyphen."
  }
}

variable "log_groups" {
  description = <<-EOT
    Log groups to manage. Each entry becomes /<service_name>/<environment>/<name>.

    Fields:
      name              Short logical name (e.g. "api", "worker"). Lowercase
                        alphanumeric, hyphens, underscores, dots.
      retention_in_days One of CloudWatch's allowed retention periods:
                        1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365,
                        400, 545, 731, 1096, 1827, 2192, 2557, 2922,
                        3288, 3653. Use 0 for never-expire (NOT recommended).
      kms_key_arn       Optional. KMS CMK ARN for SSE-KMS. When null, logs
                        are encrypted with the AWS-managed CloudWatch key.
  EOT
  type = list(object({
    name              = string
    retention_in_days = number
    kms_key_arn       = optional(string)
  }))
  default = []

  validation {
    condition     = length(distinct([for g in var.log_groups : g.name])) == length(var.log_groups)
    error_message = "Each log_groups[*].name must be unique."
  }

  validation {
    condition = alltrue([
      for g in var.log_groups : can(regex("^[a-z0-9][a-z0-9._-]{0,254}$", g.name))
    ])
    error_message = "Each log_groups[*].name must be lowercase alphanumeric with dots, hyphens, or underscores."
  }

  validation {
    condition = alltrue([
      for g in var.log_groups : contains(
        [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
        g.retention_in_days
      )
    ])
    error_message = "retention_in_days must be one of CloudWatch's allowed values (e.g., 7, 30, 90, 365, 731, 1827)."
  }
}

variable "alarms" {
  description = <<-EOT
    CloudWatch metric alarms to manage.

    Fields:
      name                Alarm name; must be unique within this module instance.
      description         Human-readable description (shown in CloudWatch console).
      namespace           CloudWatch metric namespace (e.g. "AWS/ECS", or a custom one).
      metric_name         Metric name within that namespace.
      statistic           One of: SampleCount | Average | Sum | Minimum | Maximum.
      period_seconds      Evaluation period in seconds. Must be >= 60.
      evaluation_periods  Number of periods that must breach before firing.
      threshold           Numeric threshold compared via comparison_operator.
      comparison_operator AWS metric-alarm comparison operator string.
      sns_topic_arn       Optional. Specific SNS topic to publish to. When null,
                          falls back to the module-managed topic if
                          enable_sns_topic = true; otherwise alarm publishes
                          to no destination (still visible in CloudWatch).
      dimensions          Optional. Metric dimensions, e.g. { ClusterName = "x" }.
      severity            info | warning | critical. Stored as the AlarmSeverity tag.
  EOT
  type = list(object({
    name                = string
    description         = string
    namespace           = string
    metric_name         = string
    statistic           = string
    period_seconds      = number
    evaluation_periods  = number
    threshold           = number
    comparison_operator = string
    sns_topic_arn       = optional(string)
    dimensions          = optional(map(string), {})
    severity            = optional(string, "warning")
  }))
  default = []

  validation {
    condition     = length(distinct([for a in var.alarms : a.name])) == length(var.alarms)
    error_message = "Each alarms[*].name must be unique."
  }

  validation {
    condition = alltrue([
      for a in var.alarms : contains(["SampleCount", "Average", "Sum", "Minimum", "Maximum"], a.statistic)
    ])
    error_message = "Each alarms[*].statistic must be one of: SampleCount, Average, Sum, Minimum, Maximum."
  }

  validation {
    condition = alltrue([
      for a in var.alarms : contains([
        "GreaterThanOrEqualToThreshold",
        "GreaterThanThreshold",
        "LessThanThreshold",
        "LessThanOrEqualToThreshold",
        "LessThanLowerOrGreaterThanUpperThreshold",
        "LessThanLowerThreshold",
        "GreaterThanUpperThreshold",
      ], a.comparison_operator)
    ])
    error_message = "Each alarms[*].comparison_operator must be a CloudWatch metric-alarm operator."
  }

  validation {
    condition     = alltrue([for a in var.alarms : a.period_seconds >= 60 && a.period_seconds % 60 == 0])
    error_message = "Each alarms[*].period_seconds must be >= 60 and a multiple of 60."
  }

  validation {
    condition     = alltrue([for a in var.alarms : a.evaluation_periods >= 1 && a.evaluation_periods <= 1440])
    error_message = "Each alarms[*].evaluation_periods must be between 1 and 1440."
  }

  validation {
    condition = alltrue([
      for a in var.alarms : contains(["info", "warning", "critical"], a.severity)
    ])
    error_message = "Each alarms[*].severity must be one of: info, warning, critical."
  }
}

variable "enable_sns_topic" {
  description = <<-EOT
    When true, the module creates a single SNS topic named
    <customer_slug>-<environment>-<service_name>-alarms and uses it as the
    fallback destination for any alarm that does not specify its own
    sns_topic_arn. Subscriptions to that topic are intentionally NOT
    managed here — application roots add subscriptions so subscriber
    lifecycle (email confirmations, webhook rotation) is owned closer to
    the consumer.
  EOT
  type        = bool
  default     = false
}

variable "destroy_protection" {
  description = <<-EOT
    Convention parameter — log groups, alarms, and SNS topics destroy
    cleanly with no AWS-native delete protection toggle, so this value is
    currently unused inside the module. It is accepted for variable-shape
    consistency with every other module in this repository.
  EOT
  type        = bool
  default     = false
}
