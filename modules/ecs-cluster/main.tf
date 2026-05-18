locals {
  cluster_name = coalesce(var.cluster_name_override, "${var.customer_slug}-${var.environment}")

  base_tags = {
    customer_slug = var.customer_slug
    environment   = var.environment
    module        = "ecs-cluster"
    managed_by    = "tofu"
  }
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = local.base_tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}
