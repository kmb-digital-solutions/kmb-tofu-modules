# modules/ecs-service

One Fargate ECS service: task definition, execution role, task role,
CloudWatch log group, optional ALB target-group registration, optional
ECS Exec, and CPU-target-tracking autoscaling.

## Usage

```hcl
module "api_service" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/ecs-service?ref=ecs-service/v1.0.0"

  customer_slug   = var.customer_slug
  environment     = var.environment
  service_name    = "api"
  cluster_arn     = module.ecs_cluster.cluster_arn
  container_image = "${module.ecr_api.repository_url}:${var.image_tag}"
  container_port  = 8000
  cpu             = 512
  memory          = 1024
  desired_count   = 2
  min_count       = 2
  max_count       = 10

  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [aws_security_group.api_tasks.id]
  target_group_arn   = module.alb.api_target_group_arn

  task_role_policies = [aws_iam_policy.app_dynamodb.arn]

  environment_variables = {
    LOG_LEVEL = "INFO"
    DB_HOST   = module.rds.endpoint
  }

  secret_arns = {
    DB_PASSWORD = module.rds.master_password_secret_arn
  }

  log_retention_days = 30
  log_kms_key_arn    = module.kms.logs_key_arn

  enable_execute_command = false
  destroy_protection     = var.destroy_protection
}
```

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | string | — | Customer slug. |
| `environment` | string | — | `dev` / `staging` / `prod`. |
| `service_name` | string | — | Logical service name (`api`, `worker-ai-synthesis`, etc.). |
| `cluster_arn` | string | — | ECS cluster ARN. |
| `container_image` | string | — | Full ECR URI with immutable tag. |
| `container_port` | number | `8000` | Container TCP port. |
| `cpu` | number | `256` | Fargate CPU units (256/512/1024/2048/4096/8192/16384). |
| `memory` | number | `512` | Task memory MiB. |
| `desired_count` | number | `1` | Initial task count. Autoscaling owns this after first apply. |
| `min_count` | number | `1` | Autoscaling minimum. |
| `max_count` | number | `4` | Autoscaling maximum. |
| `subnet_ids` | list(string) | — | Private subnet IDs. |
| `security_group_ids` | list(string) | — | Task ENI security groups. |
| `target_group_arn` | string | `null` | ALB target group ARN; null disables LB registration. |
| `task_role_policies` | list(string) | `[]` | IAM policy ARNs attached to the task role. |
| `environment_variables` | map(string) | `{}` | Non-secret container env. |
| `secret_arns` | map(string) | `{}` | Map of env-var name → Secrets Manager or SSM Parameter ARN. |
| `log_retention_days` | number | `7` | CloudWatch Logs retention. |
| `log_kms_key_arn` | string | `null` | CMK ARN for log encryption. |
| `enable_execute_command` | bool | `false` | Enable ECS Exec for break-glass shell access. |
| `destroy_protection` | bool | `false` | When true, service is not force-deleted on destroy. |

## Outputs

| Name | Description |
|------|-------------|
| `service_arn` | ECS service ARN. |
| `service_name` | ECS service name. |
| `task_definition_arn` | Active task definition ARN. |
| `log_group_name` | CloudWatch log group name. |
| `task_role_arn` | Task role ARN (for additional policy attachments). |
| `task_role_name` | Task role name. |

## Pitfalls handled

- **`force_delete = !var.destroy_protection`.** Non-prod services skip
  task drain on destroy, keeping the N-cycle test under the 45-min budget.
- **`ignore_changes = [desired_count]` on the service.** After first
  apply, Application Auto Scaling owns the value. Without this,
  `tofu plan` would constantly want to reset the count.
- **Deployment circuit breaker with rollback enabled.** Failed
  deployments roll back automatically; the service does not get stuck
  on a broken task definition.
- **Execution role is split from task role.** AWS managed
  `AmazonECSTaskExecutionRolePolicy` on the execution role; caller-
  supplied policies on the task role. Mixing the two is the most common
  cause of "container can pull but can't reach DynamoDB" bugs.
- **Secret ARNs grant `kms:Decrypt` on the execution role.** Secrets
  Manager's default key cycles `Decrypt` to the calling principal, but
  CMK-encrypted secrets do not — the inline policy covers both cases.
- **ECS Exec adds SSM channel permissions to the task role, not the
  execution role.** Cluster-level execute-command config is left to the
  cluster module; only `enable_execute_command` on the service is set
  here so each service opts in independently.
- **`propagate_tags = "SERVICE"`** means tasks inherit the service's
  tags, so the per-task tag set always matches the service tag set.

## `destroy_protection` behavior

- `false` (default for non-prod): `force_delete = true` on the service.
  `tofu destroy` skips task drain and removes the service immediately.
- `true` (prod): `force_delete = false`. Tasks must drain before the
  service deletes, giving operators an explicit signal that destroy was
  intentional.

The CloudWatch log group and IAM roles destroy cleanly either way. Task
definition revisions accumulate over time; AWS retains them at no
charge, and revisions are not destroyed by the module on teardown.
