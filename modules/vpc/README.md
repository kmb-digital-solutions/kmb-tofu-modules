# `modules/vpc`

VPC with public/private subnets across N AZs, IGW, NAT Gateway(s), route
tables, locked-down default security group, and optional VPC endpoints.

## Usage

```hcl
module "vpc" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/vpc?ref=vpc/v1.0.0"

  customer_slug           = var.customer_slug
  environment             = var.environment
  cidr_block              = "10.0.0.0/16"
  availability_zone_count = 2
  enable_nat_gateway      = true
  single_nat_gateway      = !var.destroy_protection
  vpc_endpoints           = ["s3", "dynamodb"]
  destroy_protection      = var.destroy_protection
}
```

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `customer_slug` | `string` | — | Customer slug used for naming and tagging. |
| `environment` | `string` | — | One of `dev`, `staging`, `prod`. |
| `cidr_block` | `string` | `"10.0.0.0/16"` | IPv4 CIDR for the VPC. |
| `availability_zone_count` | `number` | `2` | Number of AZs (1-6). |
| `enable_nat_gateway` | `bool` | `true` | Create NAT Gateway(s) for private egress. |
| `single_nat_gateway` | `bool` | `true` | One shared NAT vs. one per AZ. |
| `destroy_protection` | `bool` | `false` | Reserved for tag/policy parity across modules. |
| `vpc_endpoints` | `list(string)` | `[]` | AWS service short names (e.g., `"s3"`, `"ecr.api"`). |

## Outputs

| Name | Description |
|------|-------------|
| `vpc_id` | ID of the VPC. |
| `vpc_cidr_block` | Primary IPv4 CIDR block. |
| `public_subnet_ids` | Public subnet IDs in AZ order. |
| `private_subnet_ids` | Private subnet IDs in AZ order. |
| `default_security_group_id` | Default SG ID (rules emptied; deny-all). |
| `nat_gateway_ids` | NAT Gateway IDs. |
| `vpc_endpoint_ids` | Map of service short name to VPC endpoint ID. |
| `availability_zones` | AZ names used. |

## Pitfalls handled

See `docs/module-development.md` for the full playbook.

- **ENI orphans**: this module does NOT manage Lambdas, RDS, OpenSearch, or
  anything else that creates AWS-managed ENIs inside the VPC. Compose those
  in the application root so their lifecycle is bound to the application,
  not the VPC. This is the single most common N-cycle failure mode.
- **NAT destroy time**: each NAT Gateway destroy takes about a minute.
  `single_nat_gateway = true` on non-prod halves cycle time.
- **Deterministic subnetting**: `cidrsubnet(var.cidr_block, 4, ...)` yields
  the same subnets on every apply. Public in lower half, private in upper
  half.
- **Default SG**: `aws_default_security_group` empties out the rules so
  anything that accidentally lands in the default SG gets zero
  connectivity.

## `destroy_protection`

This module accepts `destroy_protection` for tag and interface parity with
peer modules; the VPC itself has no AWS-native deletion-protection toggle.
Pitfalls that block VPC destroy (orphan ENIs, lingering load balancers,
Lambda VPC config) are addressed by NOT managing those resources in this
module — they belong to the application root.

Operators using `single_nat_gateway = false` in non-prod should expect
longer N-cycle times.
