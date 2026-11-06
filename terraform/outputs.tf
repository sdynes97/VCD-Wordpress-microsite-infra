output "cloudflare_name_servers" {
  description = "Set these at each domain's registrar to activate the Cloudflare zone."
  value       = { for k, z in cloudflare_zone.site : z.name => z.name_servers }
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.wp.id
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.wp.name
}

output "vm_public_ip" {
  description = "Egress IP (and SSH target if ssh_allowed_cidrs is set). No web ports are open."
  value       = azurerm_public_ip.wp.ip_address
}

output "key_vault_name" {
  value = azurerm_key_vault.wp.name
}
