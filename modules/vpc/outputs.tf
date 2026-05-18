output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in AZ order."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, in AZ order."
  value       = aws_subnet.private[*].id
}

output "default_security_group_id" {
  description = "ID of the VPC's default security group (rules emptied; functions as deny-all)."
  value       = aws_default_security_group.this.id
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs. Empty when enable_nat_gateway is false; length 1 in single_nat_gateway mode; otherwise one per AZ."
  value       = aws_nat_gateway.this[*].id
}

output "vpc_endpoint_ids" {
  description = "Map of service short name to VPC endpoint ID, covering both gateway and interface endpoints."
  value = merge(
    { for k, v in aws_vpc_endpoint.gateway : k => v.id },
    { for k, v in aws_vpc_endpoint.interface : k => v.id },
  )
}

output "availability_zones" {
  description = "AZ names used for the public/private subnets, in deterministic order."
  value       = local.selected_azs
}
