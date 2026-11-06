# Non-secret production settings (committed on purpose; secrets live in
# GitHub Actions secrets / Key Vault). Replace every CHANGE-ME value.

resource_group_name = "rg-vcdwp-prod"
location            = "eastus2"
name_prefix         = "vcdwp"
vm_size             = "Standard_B2s"

admin_username       = "wpadmin"
admin_ssh_public_key = "ssh-ed25519 AAAA-CHANGE-ME wpadmin"

# Leave empty to keep port 22 closed (manage with 'az vm run-command').
ssh_allowed_cidrs = []

cloudflare_account_id = "CHANGE-ME-cloudflare-account-id"

# Your office/home egress IPs. Empty = managed challenge on wp-login/wp-admin.
wp_admin_ips = []

sites = {
  site1 = {
    zone_name       = "example.com"
    hostnames       = ["example.com", "www.example.com"]
    cloudflare_plan = "free"
  }
  site2 = {
    zone_name       = "example.org"
    hostnames       = ["example.org", "www.example.org"]
    cloudflare_plan = "free"
  }
}
