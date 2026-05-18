# observability
#
# Bundles the three primitives every service needs: CloudWatch log groups,
# CloudWatch metric alarms, and an optional module-managed SNS topic that
# alarms publish to by default. Log groups + alarms + SNS topics all
# destroy cleanly, so this module is N-cycle safe by construction.

locals {
  log_groups_by_name = {
    for g in var.log_groups : g.name => g
  }

  alarms_by_name = {
    for a in var.alarms : a.name => a
  }

  sns_topic_name = "${var.customer_slug}-${var.environment}-${var.service_name}-alarms"

  module_topic_arn = var.enable_sns_topic ? aws_sns_topic.alarms[0].arn : null

  common_tags = {
    customer_slug = var.customer_slug
    environment   = var.environment
    service       = var.service_name
    module        = "observability"
    managed_by    = "tofu"
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups_by_name

  name              = "/${var.service_name}/${var.environment}/${each.value.name}"
  retention_in_days = each.value.retention_in_days
  kms_key_id        = each.value.kms_key_arn

  tags = local.common_tags
}

resource "aws_sns_topic" "alarms" {
  count = var.enable_sns_topic ? 1 : 0

  name = local.sns_topic_name

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms_by_name

  alarm_name          = each.value.name
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  statistic           = each.value.statistic
  period              = each.value.period_seconds
  evaluation_periods  = each.value.evaluation_periods
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison_operator
  dimensions          = each.value.dimensions

  # Resolution: per-alarm sns_topic_arn wins; otherwise the
  # module-managed topic (if created); otherwise the alarm fires with
  # no notification destination. CloudWatch still records the state
  # change in either case.
  alarm_actions = compact([
    coalesce(each.value.sns_topic_arn, local.module_topic_arn)
  ])
  ok_actions = compact([
    coalesce(each.value.sns_topic_arn, local.module_topic_arn)
  ])

  treat_missing_data = "notBreaching"

  tags = merge(local.common_tags, {
    AlarmSeverity = each.value.severity
  })
}
