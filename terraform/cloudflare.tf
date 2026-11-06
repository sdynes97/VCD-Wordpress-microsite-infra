# ---------------------------------------------------------------------------
# Zones + baseline settings
# ---------------------------------------------------------------------------

resource "cloudflare_zone" "site" {
  for_each = var.sites

  account = { id = var.cloudflare_account_id }
  name    = each.value.zone_name
  type    = "full"
}

locals {
  zone_settings = {
    ssl                      = "strict"
    always_use_https         = "on"
    automatic_https_rewrites = "on"
    min_tls_version          = "1.2"
    tls_1_3                  = "on"
    security_level           = "medium"
    browser_check            = "on"
  }

  zone_setting_pairs = {
    for pair in setproduct(keys(var.sites), keys(local.zone_settings)) :
    "${pair[0]}|${pair[1]}" => { site_key = pair[0], setting = pair[1] }
  }
}

resource "cloudflare_zone_setting" "site" {
  for_each = local.zone_setting_pairs

  zone_id    = cloudflare_zone.site[each.value.site_key].id
  setting_id = each.value.setting
  value      = local.zone_settings[each.value.setting]
}

# Bot Fight Mode (Free) / Super Bot Fight Mode (Pro).
resource "cloudflare_bot_management" "site" {
  for_each = var.sites

  zone_id   = cloudflare_zone.site[each.key].id
  enable_js = true

  fight_mode                = each.value.cloudflare_plan == "free" ? true : null
  sbfm_definitely_automated = each.value.cloudflare_plan == "pro" ? "managed_challenge" : null
  sbfm_verified_bots        = each.value.cloudflare_plan == "pro" ? "allow" : null
}

# ---------------------------------------------------------------------------
# WAF
# ---------------------------------------------------------------------------

locals {
  admin_ip_set = join(" ", var.wp_admin_ips)

  admin_paths = join(" ", [
    "http.request.uri.path eq \"/wp-login.php\"",
    "or (starts_with(http.request.uri.path, \"/wp-admin\")",
    "and not http.request.uri.path in {\"/wp-admin/admin-ajax.php\" \"/wp-admin/admin-post.php\"})",
  ])

  waf_custom_rules = [
    {
      description = "Block XML-RPC"
      action      = "block"
      expression  = "http.request.uri.path eq \"/xmlrpc.php\""
    },
    {
      description = length(var.wp_admin_ips) > 0 ? "Restrict wp-login / wp-admin to admin IPs" : "Challenge wp-login / wp-admin"
      action      = length(var.wp_admin_ips) > 0 ? "block" : "managed_challenge"
      expression = (length(var.wp_admin_ips) > 0
        ? "(${local.admin_paths}) and not ip.src in {${local.admin_ip_set}}"
      : "(${local.admin_paths})")
    },
    {
      description = "Block sensitive files and PHP in uploads"
      action      = "block"
      expression = join(" or ", [
        "ends_with(lower(http.request.uri.path), \"/wp-config.php\")",
        "contains(http.request.uri.path, \"/.git\")",
        "contains(http.request.uri.path, \"/.env\")",
        "ends_with(lower(http.request.uri.path), \".sql\")",
        "http.request.uri.path in {\"/readme.html\" \"/license.txt\" \"/wp-config-sample.php\"}",
        "(starts_with(http.request.uri.path, \"/wp-content/uploads/\") and ends_with(lower(http.request.uri.path), \".php\"))",
      ])
    },
    {
      description = "Block user enumeration"
      action      = "block"
      expression = join(" ", [
        "(http.request.uri.query contains \"author=\" and not starts_with(http.request.uri.path, \"/wp-admin\"))",
        "or ((starts_with(http.request.uri.path, \"/wp-json/wp/v2/users\") or http.request.uri.query contains \"wp/v2/users\")",
        "and not http.cookie contains \"wordpress_logged_in_\")",
      ])
    },
  ]
}

resource "cloudflare_ruleset" "waf_custom" {
  for_each = var.sites

  zone_id     = cloudflare_zone.site[each.key].id
  name        = "wordpress-hardening"
  description = "WordPress custom WAF rules (managed by Terraform)"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [for r in local.waf_custom_rules : merge(r, { enabled = true })]
}

resource "cloudflare_ruleset" "rate_limit" {
  for_each = var.sites

  zone_id     = cloudflare_zone.site[each.key].id
  name        = "wordpress-rate-limit"
  description = "Login brute-force protection (managed by Terraform)"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [{
    description = "Rate limit wp-login POSTs"
    action      = "block"
    enabled     = true
    expression  = "(http.request.uri.path eq \"/wp-login.php\" and http.request.method eq \"POST\")"
    ratelimit = {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = each.value.cloudflare_plan == "pro" ? 60 : 10
      requests_per_period = each.value.cloudflare_plan == "pro" ? 10 : 5
      mitigation_timeout  = each.value.cloudflare_plan == "pro" ? 600 : 10
    }
  }]
}

# Managed rulesets require Pro or higher. On Free, Cloudflare applies its Free
# Managed Ruleset automatically.
resource "cloudflare_ruleset" "waf_managed" {
  for_each = { for k, s in var.sites : k => s if s.cloudflare_plan != "free" }

  zone_id     = cloudflare_zone.site[each.key].id
  name        = "managed-waf"
  description = "Cloudflare Managed + OWASP rulesets (managed by Terraform)"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules = [
    {
      description       = "Cloudflare Managed Ruleset"
      action            = "execute"
      enabled           = true
      expression        = "true"
      action_parameters = { id = "efb7b8c949ac4650a09736fc376e9aee" }
    },
    {
      description       = "Cloudflare OWASP Core Ruleset"
      action            = "execute"
      enabled           = true
      expression        = "true"
      action_parameters = { id = "4814384a9e5d4991b9815dcfc25d2f1f" }
    },
  ]
}

# ---------------------------------------------------------------------------
# Tunnel: cloudflared on the VM dials out to Cloudflare; no inbound ports.
# ---------------------------------------------------------------------------

resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "wp" {
  account_id    = var.cloudflare_account_id
  name          = "${var.name_prefix}-wordpress"
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.tunnel_secret.base64
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "wp" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.wp.id
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "wp" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.wp.id

  config = {
    ingress = concat(
      [
        for k in sort(keys(local.site_hostnames)) : {
          hostname = local.site_hostnames[k].hostname
          service  = "http://${local.site_hostnames[k].site_key}-wp:80"
        }
      ],
      [{ service = "http_status:404" }],
    )
  }
}

resource "cloudflare_dns_record" "site" {
  for_each = local.site_hostnames

  zone_id = cloudflare_zone.site[each.value.site_key].id
  name    = each.value.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.wp.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare Tunnel -> ${each.value.site_key} (Terraform)"
}
