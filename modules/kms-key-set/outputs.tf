output "key_arns" {
  description = "Map of purpose to primary CMK ARN."
  value       = { for p, k in aws_kms_key.this : p => k.arn }
}

output "key_ids" {
  description = "Map of purpose to primary CMK key id."
  value       = { for p, k in aws_kms_key.this : p => k.key_id }
}

output "aliases" {
  description = "Map of purpose to alias name (alias/<customer_slug>-<environment>-<purpose>)."
  value       = { for p, a in aws_kms_alias.this : p => a.name }
}

output "replica_key_arns" {
  description = "Map of purpose to replica CMK ARN. Empty when enable_multi_region is false."
  value       = { for p, k in aws_kms_replica_key.this : p => k.arn }
}
