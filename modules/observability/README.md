# `observability`

The three primitives every service needs in one module:

- CloudWatch log groups named `/<service_name>/<environment>/<name>`.
- CloudWatch metric alarms with per-alarm or module-default SNS routing.
- An optional module-managed SNS topic for alarm notifications.

Subscriptions to the SNS topic are intentionally NOT managed here —
application roots own subscriber lifecycle (email confirmations, webhook
rotation) closer to the consumer.

## Usage

```hcl
module "obs" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/observability?ref=observability/v1.0.0"

  customer_slug = var.customer_slug
  environment   = var.environment
  service_name  = "api"

  log_groups = [
    {
      name              = "app"
      retention_in_days = var.environment == "prod" ? 365 : 7
    },
    {
      name              = "access"
      retention_in_days = var.environment == "prod" ? 90 : 7
      kms_key_arn       = module.kms.log_key_arn
    },
  ]

  enable_sns_topic = true

  alarms = [
    {
      name                = "api-5xx-rate"
      description         = "5xx response rate above tolerance"
      namespace           = "AWS/ApplicationELB"
      metric_name         = "HTTPCode_Target_5XX_Count"
      statistic           = "Sum"
      period_seconds      = 60
      evaluation_periods  = 5
      threshold           = 10
      comparison_operator = "GreaterThanThreshold"
      severity            = "critical"
      dimensions = {
        LoadBalancer = aws_lb.api.arn_suffix
      }
    },
  ]

  destroy_protection = var.destroy_protection
}
```

## Variables

| Name                 | Type           | Default | Description |
|----------------------|----------------|---------|-------------|
| `customer_slug`      | `string`       | —       | Used for tagging and the SNS topic name. |
| `environment`        | `string`       | —       | `dev`, `staging`, or `prod`. |
| `service_name`       | `string`       | —       | Used in log group paths and SNS topic name. |
| `log_groups`         | `list(object)` | `[]`    | Log groups to manage. |
| `alarms`             | `list(object)` | `[]`    | Metric alarms to manage. |
| `enable_sns_topic`   | `bool`         | `false` | Create a fallback SNS topic for alarms. |
| `destroy_protection` | `bool`         | `false` | Convention parameter; unused inside this module. |

### `log_groups` shape

```hcl
list(object({
  name              = string  # short logical name (e.g. "api")
  retention_in_days = number  # one of CloudWatch's allowed values
  kms_key_arn       = optional(string)
}))
```

Each entry creates `/<service_name>/<environment>/<name>`. `retention_in_days`
must be one of CloudWatch's allowed values: `1, 3, 5, 7, 14, 30, 60, 90,
120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288,
3653` (or `0` for never-expire — not recommended).

### `alarms` shape

```hcl
list(object({
  name                = string
  description         = string
  namespace           = string
  metric_name         = string
  statistic           = string  # SampleCount | Average | Sum | Minimum | Maximum
  period_seconds      = number  # >= 60, multiple of 60
  evaluation_periods  = number  # 1..1440
  threshold           = number
  comparison_operator = string  # CloudWatch operator
  sns_topic_arn       = optional(string)
  dimensions          = optional(map(string), {})
  severity            = optional(string, "warning")  # info | warning | critical
}))
```

### SNS resolution order

For each alarm, the destination resolves to:

1. The alarm's own `sns_topic_arn` if set.
2. Else the module-managed topic if `enable_sns_topic = true`.
3. Else no destination — the alarm still transitions to `ALARM` state
   and is visible in CloudWatch, but publishes nowhere.

## Outputs

| Name              | Type          | Description |
|-------------------|---------------|-------------|
| `log_group_names` | `map(string)` | Input name → fully-qualified log group name. |
| `log_group_arns`  | `map(string)` | Input name → log group ARN. |
| `alarm_arns`      | `map(string)` | Alarm name → alarm ARN. |
| `sns_topic_arn`   | `string`      | Module-managed SNS topic ARN, or `null` when `enable_sns_topic = false`. |

## Pitfalls handled

- **Log groups destroy cleanly.** No `force_destroy`-equivalent toggle
  required; CloudWatch removes the group and its contents in one call.
- **Alarms destroy cleanly.** Metric data is retained in CloudWatch
  Metrics independently — destroying an alarm never touches the metric
  itself.
- **SNS topic destroys cleanly.** If subscribers exist when the topic
  is destroyed, those subscriptions orphan as expected; the topic is
  still removed. Because subscriptions are owned by the application
  root rather than this module, subscriber drift never blocks an
  N-cycle.
- **KMS keys are inputs, not managed here.** When a log group is given
  a `kms_key_arn`, that key must already exist (typically from
  `kms-key-set`). This module never deletes keys, so a re-apply against
  a fresh log group rebinds to the same alias and continues working.
- **Missing data treated as not-breaching.** Alarms default to
  `treat_missing_data = "notBreaching"` to avoid spurious ALARM during
  blue/green cutovers and cold starts.

## `destroy_protection` behavior

CloudWatch log groups, metric alarms, and SNS topics do not expose
delete-protection toggles in AWS. The variable is accepted on the
interface for shape consistency with every other module in this
repository.
