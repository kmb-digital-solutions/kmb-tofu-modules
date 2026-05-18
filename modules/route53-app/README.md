# `route53-app`

Manage records under an **existing** Route 53 hosted zone. Hosted zone
management is intentionally out of scope — zones are pre-existing customer
assets whose lifecycle outlives any single application stack.

## Usage

```hcl
module "dns" {
  source = "git::https://github.com/kmb-digital-solutions/kmb-tofu-modules.git//modules/route53-app?ref=route53-app/v1.0.0"

  customer_slug  = var.customer_slug
  environment    = var.environment
  hosted_zone_id = data.aws_route53_zone.customer.zone_id

  records = [
    # Literal A record
    {
      name    = "api"
      type    = "A"
      ttl     = 60
      records = ["198.51.100.10"]
    },
    # Alias to a load balancer
    {
      name    = "app"
      type    = "A"
      ttl     = 300
      records = []
      alias_target = {
        name                   = aws_lb.web.dns_name
        zone_id                = aws_lb.web.zone_id
        evaluate_target_health = true
      }
    },
    # CNAME for a CDN
    {
      name    = "static"
      type    = "CNAME"
      ttl     = 300
      records = ["d1234.cloudfront.net"]
    },
  ]

  destroy_protection = var.destroy_protection
}
```

## Variables

| Name                 | Type           | Default | Description |
|----------------------|----------------|---------|-------------|
| `customer_slug`      | `string`       | —       | Customer slug used for tagging. |
| `environment`        | `string`       | —       | `dev`, `staging`, or `prod`. |
| `hosted_zone_id`     | `string`       | —       | ID of the existing Route 53 zone. |
| `records`            | `list(object)` | —       | Records to manage (see below). |
| `destroy_protection` | `bool`         | `false` | Convention parameter; unused inside this module. |

### `records` shape

```hcl
list(object({
  name         = string                            # subdomain (e.g. "app" or "api.app")
  type         = string                            # A | AAAA | CNAME
  ttl          = number                            # 0–86400 seconds; ignored for alias
  records      = list(string)                      # literal rrdata; empty when alias_target set
  alias_target = optional(object({
    name                   = string
    zone_id                = string
    evaluate_target_health = bool
  }))
}))
```

`ttl` guidance: use `60` for dynamic targets that may shift (e.g. blue/green
cutover), `300` for stable records.

Each `(name, type)` pair must be unique within `records`.

## Outputs

| Name           | Type               | Description |
|----------------|--------------------|-------------|
| `record_fqdns` | `map(string)`      | Map of input `name` to the fully-qualified record name written to Route 53. |

## Pitfalls handled

- **Records destroy cleanly.** No special handling required — `tofu destroy`
  removes every record this module created, and the hosted zone (which we
  do NOT manage) is untouched.
- **No hosted-zone management.** The module deliberately takes a
  `hosted_zone_id` input rather than creating one. Zones outlive
  applications; an application teardown must not erase the zone.
- **Stable `for_each` keys.** Records are keyed by `name|type`, so
  reordering the input list does not force replacement.
- **Alias vs. literal mutual exclusion.** Variable validation rejects
  records that mix `alias_target` with non-empty `records` (or that omit
  both). This catches mistakes at `tofu validate` time instead of
  Route 53's runtime error.

## `destroy_protection` behavior

Route 53 records do not expose a delete-protection toggle in AWS, so this
flag is currently unused inside the module. It is accepted on the
interface for shape consistency with every other module in this
repository, so application roots can pass a single bool everywhere.
