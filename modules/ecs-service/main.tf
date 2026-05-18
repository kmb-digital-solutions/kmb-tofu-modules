data "aws_region" "current" {}

locals {
  name_prefix  = "${var.customer_slug}-${var.environment}-${var.service_name}"
  cluster_name = element(split("/", var.cluster_arn), length(split("/", var.cluster_arn)) - 1)

  base_tags = {
    customer_slug = var.customer_slug
    environment   = var.environment
    module        = "ecs-service"
    managed_by    = "tofu"
    service       = var.service_name
  }

  log_group_name = "/ecs/${var.customer_slug}/${var.environment}/${var.service_name}"

  container_environment = [
    for k, v in var.environment_variables : {
      name  = k
      value = v
    }
  ]

  container_secrets = [
    for k, v in var.secret_arns : {
      name      = k
      valueFrom = v
    }
  ]

  container_definition = jsonencode([
    {
      name      = var.service_name
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        },
      ]

      environment = local.container_environment
      secrets     = local.container_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group_name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = var.service_name
        }
      }
    }
  ])

  # Secrets-Manager ARNs may carry the random "-AbCdEf" suffix; SSM
  # Parameter ARNs do not. The execution-role policy needs both shapes.
  secret_arns_list = values(var.secret_arns)
}

# ---------- IAM ----------

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-execution"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Permit the execution role to read this service's secrets and to use the
# log-group's KMS key (if any). Built conditionally so an empty
# secret_arns map does not produce an empty Statement.
data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secret_arns) > 0 || var.log_kms_key_arn != null ? 1 : 0

  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []
    content {
      sid = "ReadSecrets"
      actions = [
        "secretsmanager:GetSecretValue",
        "ssm:GetParameters",
        "ssm:GetParameter",
        "kms:Decrypt",
      ]
      resources = local.secret_arns_list
    }
  }

  dynamic "statement" {
    for_each = var.log_kms_key_arn != null ? [1] : []
    content {
      sid = "UseLogKmsKey"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      resources = [var.log_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "execution_inline" {
  count = length(var.secret_arns) > 0 || var.log_kms_key_arn != null ? 1 : 0

  name   = "${local.name_prefix}-execution-inline"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "task_policies" {
  for_each = toset(var.task_role_policies)

  role       = aws_iam_role.task.name
  policy_arn = each.value
}

# ECS Exec requires SSM messages on the task role.
data "aws_iam_policy_document" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    sid = "AllowECSExecSSM"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.log_kms_key_arn != null ? [1] : []
    content {
      sid = "AllowECSExecLogKmsKey"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = [var.log_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "${local.name_prefix}-task-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec[0].json
}

# ---------- Logging ----------

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = local.base_tags
}

# ---------- Task definition + service ----------

resource "aws_ecs_task_definition" "this" {
  family                   = local.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = local.container_definition

  tags = local.base_tags
}

resource "aws_ecs_service" "this" {
  name                   = var.service_name
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  force_delete           = !var.destroy_protection
  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.service_name
      container_port   = var.container_port
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # After first apply, autoscaling owns desired_count. Drift here is
    # expected and not a configuration change.
    ignore_changes = [desired_count]
  }

  tags = local.base_tags
}

# ---------- Application Auto Scaling ----------

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${local.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name_prefix}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
