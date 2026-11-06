locals {
  location = coalesce(var.location, data.azurerm_resource_group.wp.location)

  # One DNS record + tunnel ingress rule per hostname.
  site_hostnames = merge([
    for key, site in var.sites : {
      for host in site.hostnames : "${key}|${host}" => {
        site_key = key
        hostname = host
      }
    }
  ]...)

  tunnel_secret_name = "cloudflared-tunnel-token"
}
