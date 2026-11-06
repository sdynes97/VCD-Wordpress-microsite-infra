# ---------------------------------------------------------------------------
# Azure
# ---------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Existing workload resource group (created by bootstrap/Initialize-TerraformBootstrap.ps1)."
  type        = string
}

variable "location" {
  description = "Azure region. Defaults to the resource group's region when null."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Short prefix used in Azure resource names (lowercase letters/digits)."
  type        = string
  default     = "vcdwp"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.name_prefix))
    error_message = "name_prefix must be 2-10 lowercase letters/digits, starting with a letter."
  }
}

variable "vm_size" {
  description = "VM size. B2s (2 vCPU / 4 GiB) comfortably runs two low-traffic WordPress sites."
  type        = string
  default     = "Standard_B2s"
}

variable "os_disk_size_gb" {
  description = "OS disk size. WordPress files, databases and local dumps all live here."
  type        = number
  default     = 64
}

variable "admin_username" {
  description = "Linux admin user."
  type        = string
  default     = "wpadmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key (OpenSSH format) for the admin user. Password auth is disabled."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH to the VM's public IP. Empty = no inbound SSH (use 'az vm run-command')."
  type        = list(string)
  default     = []
}

variable "vnet_address_space" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_prefix" {
  type    = string
  default = "10.20.1.0/24"
}

variable "backup_retention_days" {
  description = "Daily Azure Backup recovery points to keep."
  type        = number
  default     = 14
}

variable "backup_time_utc" {
  description = "Daily backup time (HH:MM, UTC)."
  type        = string
  default     = "07:00"
}

variable "tags" {
  type = map(string)
  default = {
    workload   = "wordpress-microsites"
    managed-by = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Container images (WordPress core self-updates inside its volume; the image
# tag mostly controls PHP/Apache versions).
# ---------------------------------------------------------------------------

variable "wordpress_image" {
  type    = string
  default = "wordpress:php8.3-apache"
}

variable "mariadb_image" {
  type    = string
  default = "mariadb:11.4"
}

variable "cloudflared_image" {
  type    = string
  default = "cloudflare/cloudflared:latest"
}

# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (Dashboard > Account home > Account ID)."
  type        = string
}

variable "sites" {
  description = <<-EOT
    WordPress sites keyed by a short id (lowercase letters/digits; used for container names).
      zone_name       - Cloudflare zone (registered domain), e.g. "example.com"
      hostnames       - hostnames served by this site, e.g. ["example.com", "www.example.com"]
      cloudflare_plan - "free" or "pro". Pro unlocks the Cloudflare Managed + OWASP rulesets.
                        The plan itself is purchased in the Cloudflare dashboard.
  EOT
  type = map(object({
    zone_name       = string
    hostnames       = list(string)
    cloudflare_plan = optional(string, "free")
  }))

  validation {
    condition     = alltrue([for k in keys(var.sites) : can(regex("^[a-z][a-z0-9]{0,14}$", k))])
    error_message = "Site keys must be 1-15 lowercase letters/digits, starting with a letter."
  }

  validation {
    condition     = alltrue([for s in values(var.sites) : contains(["free", "pro"], s.cloudflare_plan)])
    error_message = "cloudflare_plan must be \"free\" or \"pro\"."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.sites) : [
        for h in s.hostnames : h == s.zone_name || endswith(h, ".${s.zone_name}")
      ]
    ]))
    error_message = "Every hostname must be the zone apex or a subdomain of that site's zone_name."
  }
}

variable "wp_admin_ips" {
  description = <<-EOT
    IPs/CIDRs allowed to reach /wp-login.php and /wp-admin. When empty, those paths get a
    Cloudflare managed challenge instead of a hard block.
  EOT
  type        = list(string)
  default     = []
}
