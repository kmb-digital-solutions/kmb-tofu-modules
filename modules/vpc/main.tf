###############################################################################
# Module: vpc
#
# Provisions a VPC with public/private subnets across N AZs, IGW, NAT
# Gateway(s), route tables, a locked-down default security group, and
# optional VPC endpoints.
#
# Pitfalls handled (see docs/module-development.md):
#   - ENI orphans: this module does NOT manage Lambdas, RDS, or other
#     resources that create AWS-managed ENIs. Application roots compose
#     those separately so their lifecycle is bound to the application.
#   - NAT destroy time: var.single_nat_gateway = true halves cycle time
#     on non-prod by deploying a single shared NAT.
#   - Deterministic subnetting: cidrsubnet() with /4 newbits over the VPC
#     CIDR produces /20 subnets for the canonical /16 input, lower half
#     public and upper half private.
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  selected_azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # Subnet allocation. /16 input → /20 subnets. Lower half (indices 0..7)
  # reserved for public; upper half (indices 8..15) reserved for private.
  # availability_zone_count is constrained to <=6 so this never overflows.
  public_subnet_cidrs  = [for i in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 4, i)]
  private_subnet_cidrs = [for i in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 4, i + 8)]

  # NAT strategy resolution: explicit nat_strategy wins; otherwise fall back
  # to the legacy enable_nat_gateway flag for backwards compatibility.
  effective_nat_strategy = (
    var.nat_strategy != null ? var.nat_strategy :
    var.enable_nat_gateway ? "gateway" :
    "none"
  )

  use_nat_gateway  = local.effective_nat_strategy == "gateway"
  use_nat_instance = local.effective_nat_strategy == "instance"
  has_egress       = local.effective_nat_strategy != "none"

  nat_gateway_count = local.use_nat_gateway ? (var.single_nat_gateway ? 1 : var.availability_zone_count) : 0

  # Gateway endpoints are free; interface endpoints incur hourly + data costs.
  gateway_endpoint_services   = [for s in var.vpc_endpoints : s if contains(["s3", "dynamodb"], s)]
  interface_endpoint_services = [for s in var.vpc_endpoints : s if !contains(["s3", "dynamodb"], s)]

  # `<customer>-<env>[-<app>]`. App-aware namespacing kicks in when the
  # caller passes a non-empty application_name.
  name_prefix_base = var.application_name == "" ? "${var.customer_slug}-${var.environment}" : "${var.customer_slug}-${var.environment}-${var.application_name}"

  tags = merge(
    {
      customer_slug = var.customer_slug
      environment   = var.environment
      module        = "vpc"
      managed_by    = "tofu"
    },
    var.application_name == "" ? {} : { application = var.application_name },
  )
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-vpc"
  })
}

# Empty out the default security group's rules. Anything that lands in the
# default SG by accident gets zero connectivity.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-default-deny"
  })
}

###############################################################################
# Internet Gateway + public subnets
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.selected_azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                     = "${local.name_prefix_base}-public-${local.selected_azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
    tier                     = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-public-rt"
  })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# Private subnets + NAT egress
###############################################################################

resource "aws_subnet" "private" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.selected_azs[count.index]

  tags = merge(local.tags, {
    Name                              = "${local.name_prefix_base}-private-${local.selected_azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
    tier                              = "private"
  })
}

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-nat-eip-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-nat-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

# One private route table per AZ so we can point each at its own NAT (or the
# shared NAT in single_nat_gateway mode).
resource "aws_route_table" "private" {
  count = var.availability_zone_count

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-private-rt-${local.selected_azs[count.index]}"
  })
}

resource "aws_route" "private_default" {
  count = local.has_egress ? var.availability_zone_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  # Exactly one of these gets set per route, dictated by nat_strategy.
  nat_gateway_id = local.use_nat_gateway ? (
    var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
  ) : null
  network_interface_id = local.use_nat_instance ? aws_network_interface.nat_instance[0].id : null
}

###############################################################################
# NAT instance (fck-nat) — cheap alternative to NAT Gateway
#
# When nat_strategy = "instance", a single t4g.nano in the first public subnet
# replaces the NAT Gateway. ~$3.50/mo all-in vs ~$32/mo for the Gateway.
# Single AZ, single point of failure — acceptable for sandbox/demo workloads.
# The fck-nat AMI ships from a public, community-maintained registry
# (https://github.com/AndrewGuenther/fck-nat) and auto-applies security
# updates on boot.
###############################################################################

data "aws_ami" "fck_nat" {
  count = local.use_nat_instance ? 1 : 0

  most_recent = true
  owners      = ["568608671756"] # fck-nat public AMI owner

  # fck-nat retired the amzn2 line in early 2026 and now publishes
  # only al2023 + nat64 images. The al2023 stream is the current GA;
  # only arm64 (Graviton) builds are published (cheaper + ENA-capable).
  filter {
    name   = "name"
    values = ["fck-nat-al2023-hvm-*-arm64-ebs"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "nat_instance" {
  count = local.use_nat_instance ? 1 : 0

  name        = "${local.name_prefix_base}-nat-instance"
  description = "fck-nat instance: ingress from VPC CIDR, egress to the internet."
  vpc_id      = aws_vpc.this.id

  # Ingress: any traffic from the private subnets (the NAT forwards it).
  ingress {
    description = "All traffic from within the VPC."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cidr_block]
  }

  # Egress: unrestricted; the instance forwards on behalf of workloads.
  egress {
    description = "Outbound to the internet."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-nat-instance"
  })
}

# Dedicated ENI so the private route table's network_interface_id reference
# stays stable across instance replacements. The instance attaches to this
# ENI via network_interface block below.
resource "aws_network_interface" "nat_instance" {
  count = local.use_nat_instance ? 1 : 0

  subnet_id         = aws_subnet.public[0].id
  security_groups   = [aws_security_group.nat_instance[0].id]
  source_dest_check = false # MUST be false for NAT forwarding to work

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-nat-instance-eni"
  })
}

resource "aws_eip" "nat_instance" {
  count = local.use_nat_instance ? 1 : 0

  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-nat-instance-eip"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_eip_association" "nat_instance" {
  count = local.use_nat_instance ? 1 : 0

  allocation_id        = aws_eip.nat_instance[0].id
  network_interface_id = aws_network_interface.nat_instance[0].id
}

resource "aws_instance" "nat_instance" {
  count = local.use_nat_instance ? 1 : 0

  ami           = data.aws_ami.fck_nat[0].id
  instance_type = var.nat_instance_type

  # Attach the pre-created ENI as the primary interface so route-table
  # references survive instance replacement (replacement is rare, but the
  # whole point of using an ENI is decoupling the route from the instance).
  network_interface {
    network_interface_id = aws_network_interface.nat_instance[0].id
    device_index         = 0
  }

  # IMDSv2 required (best practice; protects against SSRF-style attacks
  # that abuse the metadata endpoint to read instance credentials).
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Source/dest check is configured on the ENI above; no instance-level
  # override needed.

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-nat-instance"
  })
}

resource "aws_route_table_association" "private" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# VPC endpoints
#
# Gateway endpoints (s3, dynamodb) attach to all private route tables for
# free private connectivity. Interface endpoints get a dedicated SG that
# allows 443/tcp from within the VPC CIDR only.
###############################################################################

data "aws_region" "current" {}

resource "aws_security_group" "interface_endpoints" {
  count = length(local.interface_endpoint_services) > 0 ? 1 : 0

  name        = "${local.name_prefix_base}-vpce-interface"
  description = "Allow HTTPS from within the VPC to interface VPC endpoints."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.cidr_block]
  }

  egress {
    description = "Stateful response traffic only; no outbound initiation needed."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-vpce-interface"
  })
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = toset(local.gateway_endpoint_services)

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-vpce-${each.value}"
  })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = aws_security_group.interface_endpoints[*].id
  private_dns_enabled = true

  tags = merge(local.tags, {
    Name = "${local.name_prefix_base}-vpce-${each.value}"
  })
}
