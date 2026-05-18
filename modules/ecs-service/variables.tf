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

variable "service_name" {
  description = "Logical service name (e.g. 'api', 'worker-ai-synthesis'). Used in resource naming and the log group path."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$", var.service_name))
    error_message = "service_name must be 2-64 chars, lowercase alphanumeric and hyphens, not start or end with a hyphen."
  }
}

variable "cluster_arn" {
  description = "ECS cluster ARN to attach the service to. Sourced from modules/ecs-cluster.cluster_arn."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:ecs:[a-z0-9-]+:[0-9]+:cluster/[a-zA-Z0-9_-]+$", var.cluster_arn))
    error_message = "cluster_arn must be a valid ECS cluster ARN."
  }
}

variable "container_image" {
  description = "Full container image URI including tag (e.g. '123.dkr.ecr.us-east-1.amazonaws.com/app:1.2.3'). Tags should be immutable in production."
  type        = string

  validation {
    condition     = length(var.container_image) > 0
    error_message = "container_image must be non-empty."
  }
}

variable "container_port" {
  description = "TCP port the container listens on. The task definition exposes this port and the ALB target group registers against it."
  type        = number
  default     = 8000

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "cpu" {
  description = "Fargate task CPU units. Must be one of the AWS-supported pairs (256, 512, 1024, 2048, 4096, 8192, 16384). Validated against AWS Fargate CPU/memory matrix."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be one of: 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "memory" {
  description = "Fargate task memory in MiB. Must be valid for the chosen cpu per the AWS Fargate matrix; the module does not enforce the matrix beyond a sane minimum."
  type        = number
  default     = 512

  validation {
    condition     = var.memory >= 512 && var.memory <= 122880
    error_message = "memory must be between 512 and 122880 MiB."
  }
}

variable "desired_count" {
  description = "Initial desired task count for the service. After first apply, autoscaling owns this value; ignore_changes is set on desired_count."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 1000
    error_message = "desired_count must be between 0 and 1000."
  }
}

variable "min_count" {
  description = "Application Auto Scaling minimum task count."
  type        = number
  default     = 1

  validation {
    condition     = var.min_count >= 0 && var.min_count <= 1000
    error_message = "min_count must be between 0 and 1000."
  }
}

variable "max_count" {
  description = "Application Auto Scaling maximum task count. Must be >= min_count."
  type        = number
  default     = 4

  validation {
    condition     = var.max_count >= 1 && var.max_count <= 5000
    error_message = "max_count must be between 1 and 5000."
  }
}

variable "subnet_ids" {
  description = "Private subnet IDs for the awsvpc network interface. At least one required; multiple subnets enable AZ spread."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must contain at least one subnet."
  }
}

variable "security_group_ids" {
  description = "Security group IDs to attach to the task ENI. Must permit ingress to container_port from the ALB SG (if used) and egress as the workload requires."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "security_group_ids must contain at least one security group."
  }
}

variable "target_group_arn" {
  description = "Optional ALB target group ARN. When set, the service registers tasks with this target group. When null, the service runs without a load balancer (e.g. workers)."
  type        = string
  default     = null

  validation {
    condition     = var.target_group_arn == null || can(regex("^arn:aws[a-zA-Z-]*:elasticloadbalancing:[a-z0-9-]+:[0-9]+:targetgroup/[a-zA-Z0-9_-]+/[a-f0-9]+$", var.target_group_arn))
    error_message = "target_group_arn must be a valid ALB target group ARN or null."
  }
}

variable "task_role_policies" {
  description = "IAM policy ARNs to attach to the task role (NOT the execution role). These are the policies the application code uses for AWS API calls."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.task_role_policies : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]*:policy/.+$", arn))])
    error_message = "Each task_role_policies entry must be a valid IAM policy ARN."
  }
}

variable "environment_variables" {
  description = "Non-secret container environment variables. Each entry is added to the task definition's `environment` list."
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = <<-EOT
    Map of container env var name → Secrets Manager secret ARN or SSM
    Parameter ARN. Each entry is added to the task definition's `secrets`
    list and the value is injected at container start. The execution role
    is granted Decrypt/GetSecretValue/GetParameters for these ARNs.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for arn in values(var.secret_arns) : can(regex("^arn:aws[a-zA-Z-]*:(secretsmanager|ssm):", arn))])
    error_message = "Each secret_arns value must be a Secrets Manager or SSM Parameter ARN."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the service's log group. Valid AWS values; 7 days for non-prod, longer for prod."
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the AWS-supported retention values."
  }
}

variable "log_kms_key_arn" {
  description = "Optional CMK ARN for log group encryption. When null, AWS owned key is used. CMK is required for HIPAA/PHI workloads."
  type        = string
  default     = null

  validation {
    condition     = var.log_kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]+:key/[a-f0-9-]+$", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be a valid KMS key ARN or null."
  }
}

variable "enable_log_kms_policy" {
  description = <<-EOT
    Plan-time-known flag indicating whether log_kms_key_arn will be set
    when applied. Used by count/for_each expressions that cannot depend on
    the ARN value directly (which may be derived from a sibling module's
    apply-time output). When true, the caller MUST also set log_kms_key_arn
    to a real ARN — null with enable_log_kms_policy=true is a misuse.
  EOT
  type        = bool
  default     = false
}

variable "enable_execute_command" {
  description = <<-EOT
    Enable ECS Exec on the service for break-glass shell access into
    running tasks. When true, the task role is granted the SSM channel
    permissions and command output is logged to the same CloudWatch log
    group with the prefix 'exec/'. Audit retention follows
    log_retention_days.
  EOT
  type        = bool
  default     = false
}

variable "destroy_protection" {
  description = <<-EOT
    When true (prod), the module emits safe-but-immortal settings:
    force_delete = false on the service so destroying with running tasks
    fails until they are drained explicitly. When false (non-prod),
    force_delete = true so N-cycle tests can teardown without waiting
    for drain. Tags carry the value either way.
  EOT
  type        = bool
  default     = false
}
