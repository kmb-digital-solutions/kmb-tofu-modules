# modules/ecs-cluster

ECS Fargate cluster with FARGATE + FARGATE_SPOT capacity providers and
optional Container Insights. Per-service capabilities like ECS Exec are
configured on the service, not the cluster.

## Usage

```hcl
module "ecs_cluster" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/ecs-cluster?ref=ecs-cluster/v1.0.0"

  customer_slug             = var.customer_slug
  environment               = var.environment
  enable_container_insights = true
  destroy_protection        = var.destroy_protection
}
```

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | string | — | Customer slug; lowercase alphanumeric and hyphens, 3-40 chars. |
| `environment` | string | — | One of `dev`, `staging`, `prod`. |
| `cluster_name_override` | string | `null` | Explicit cluster name. When `null`, the cluster is named `<customer_slug>-<environment>`. |
| `enable_container_insights` | bool | `true` | Enable CloudWatch Container Insights. |
| `destroy_protection` | bool | `false` | Tag/policy consistency with other modules; ECS clusters destroy cleanly when empty. |

## Outputs

| Name | Description |
|------|-------------|
| `cluster_id` | ECS cluster ID. |
| `cluster_name` | ECS cluster name. |
| `cluster_arn` | ECS cluster ARN. |

## Pitfalls handled

- **Capacity providers attached as a separate resource.** Using
  `aws_ecs_cluster_capacity_providers` instead of the deprecated
  `capacity_providers` argument on `aws_ecs_cluster` avoids the noisy
  diff and lets the cluster create cleanly before its FARGATE_SPOT
  association is established.
- **No execute-command logging configuration on the cluster.** That is
  per-service in the `ecs-service` module so each service can opt in
  with its own log group.
- **Container Insights is a `setting{}` block, not an attribute.** AWS
  provider 5.x accepts only the block form.

## `destroy_protection` behavior

ECS clusters with zero services destroy in seconds. The variable is
accepted for cross-module symmetry but does not change cluster
configuration. The services that reference this cluster carry their own
`force_delete` logic.
