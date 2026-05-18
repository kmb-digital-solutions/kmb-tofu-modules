output "record_fqdns" {
  description = "Map of record name (as provided in var.records[*].name) to the fully-qualified domain name written into the hosted zone."
  value = {
    for r in var.records :
    r.name => aws_route53_record.this["${r.name}|${r.type}"].fqdn
  }
}
