# VCD WordPress microsite infrastructure

Terraform for two (or more) low-cost, locked-down WordPress sites on Azure, fronted by Cloudflare's WAF.

```
 Visitors ──HTTPS──▶ Cloudflare edge (WAF, rate limiting, bot fight, TLS)
                          │
                          │  Cloudflare Tunnel (outbound-only from the VM)
                          ▼
 Azure VM (Ubuntu 24.04, Trusted Launch, NSG: no inbound)
   └─ Docker Compose
        ├─ cloudflared ──▶ site1-wp (Apache/PHP) ──▶ site1-db (MariaDB, internal net)
        └─              ──▶ site2-wp (Apache/PHP) ──▶ site2-db (MariaDB, internal net)
```

* **No open web ports.** The VM has no inbound rules; cloudflared dials out to Cloudflare. The origin can't be reached by going around the WAF.
* **Secrets stay off disk images and out of git.** The tunnel token sits in Key Vault and the VM reads it with its managed identity. DB passwords are generated on the VM at first boot. GitHub Actions uses OIDC, so no Azure secret is stored.
* **Per-site isolation.** Each site has its own WordPress and MariaDB containers and its own internal network. The databases have no internet access.

## Approximate monthly cost

| Item | Cost (USD, pay-as-you-go) |
|---|---|
| VM Standard_B2s + 64 GB StandardSSD | ~$35 |
| Standard public IP (egress only) | ~$4 |
| Azure Backup (1 VM, daily, 14 days, LRS) | ~$5–10 |
| Key Vault, state storage | <$1 |
| Cloudflare Free ×2 / Pro ×2 | $0 / $40 |
| **Total** | **~$45–55 (Free) / ~$85–95 (Pro)** |

Cloudflare **Pro** adds the Cloudflare Managed and OWASP Core rulesets. Set `cloudflare_plan = "pro"` for a site once you've bought the plan in the Cloudflare dashboard.

## Repository layout

```
bootstrap/Initialize-TerraformBootstrap.ps1   one-time Azure setup (state, RGs, OIDC identity, RBAC)
terraform/
  versions.tf         providers + azurerm backend (partial config)
  variables.tf        inputs
  azure.tf            VNet/NSG, VM, Key Vault, Recovery Services vault
  cloudflare.tf       zones, settings, WAF/rate-limit rulesets, tunnel, DNS
  vm_config.tf        cloud-init rendering
  templates/          compose file, scripts, systemd unit, cron, PHP/Apache config
  environments/
    prod.tfvars       non-secret settings (committed)
.github/workflows/terraform.yml   plan on PR, apply on merge to main
```

## Setup

### 1. Azure bootstrap (once)

From `E:\source\VCD-Wordpress-microsite-infra`:

```powershell
Install-Module Az -Scope CurrentUser   # if needed
Connect-AzAccount
./bootstrap/Initialize-TerraformBootstrap.ps1 -SubscriptionId '<subscription-guid>' -Location eastus2 -GrantCurrentUser
```

The script is idempotent. It prints `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `TFSTATE_RESOURCE_GROUP` and `TFSTATE_STORAGE_ACCOUNT`. If `gh` is installed and authenticated, it sets them as repo variables for you.

The GitHub Actions identity gets only: Contributor, RBAC Administrator and Key Vault Secrets Officer on the **workload resource group**, plus Storage Blob Data Contributor on the **state account**.

### 2. Cloudflare API token

Create an account-owned API token with these permissions:

* **Account**: Cloudflare Tunnel: Edit
* **Zone** (all zones in the account): Zone: Edit, Zone Settings: Edit, DNS: Edit, Zone WAF: Edit, Bot Management: Edit

### 3. GitHub settings

* **Variables:** the five values from step 1.
* **Secret:** `CLOUDFLARE_API_TOKEN`.
* **Environment:** `production`. Add yourself as a required reviewer if you want a manual approval before `apply`.

### 4. Fill in `terraform/environments/prod.tfvars`

Replace every `CHANGE-ME`: the SSH public key, the Cloudflare account ID, the real domains in `sites`, and the admin IPs in `wp_admin_ips`.

### 5. Deploy

Open a PR to get a plan, then merge to apply. After the first apply:

1. Point each domain's registrar at the name servers in the `cloudflare_name_servers` output.
2. When the zone is active, the sites answer at their hostnames with the WordPress installer. Lock each one down by restoring your migrated site (below) or by completing the installer right away.

To run it locally instead (PowerShell):

```powershell
cd terraform
Copy-Item environments/backend.hcl.example environments/backend.hcl   # edit values
$env:ARM_SUBSCRIPTION_ID = '<subscription-guid>'
$env:CLOUDFLARE_API_TOKEN = '<token>'
terraform init -backend-config=environments/backend.hcl
terraform plan -var-file=environments/prod.tfvars
```

## Migrating from WP Engine

1. On WP Engine, export each site with **All-in-One WP Migration** or **WP Migrate**. These plugins also rewrite URLs on import.
2. Remove the WP Engine-specific pieces: `wp-content/mu-plugins/wpengine-common*`, `mu-plugins/slt-force-strong-passwords.php`, `mu-plugins/wpe-*`. This stack generates its own `wp-config.php`, so don't carry over WP Engine's.
3. Before the DNS cutover, test against a temporary hostname (e.g. `new.example.com` in `hostnames`), then import.
4. Lower TTLs a day ahead, then switch name servers at the registrar.

Uploads are capped at **100 MB** by Cloudflare. Larger migration files need splitting, or a copy onto the VM over SSH.

## Operations

All commands run on the VM in `/opt/wordpress`. Use SSH if `ssh_allowed_cidrs` is set, otherwise:

```powershell
az vm run-command invoke -g rg-vcdwp-prod -n vm-vcdwp --command-id RunShellScript --scripts "cd /opt/wordpress && docker compose ps"
```

| Task | How |
|---|---|
| Status / logs | `docker compose ps`, `docker compose logs -f site1-wp` |
| Rotate tunnel token | Rotate in Cloudflare, `terraform apply` (updates Key Vault), then `systemctl reload wordpress-stack` |
| DB dumps | Nightly at 06:30 UTC to `/opt/wordpress/backups` (7 days), included in VM backups |
| VM backups | Azure Backup daily at 07:00 UTC, 14-day retention. Restore from the Recovery Services vault. |
| Patching | OS: unattended-upgrades (auto-reboot 08:30 UTC if needed). Containers: weekly `docker compose pull`. WordPress core minor releases auto-update; plugins are managed in WP admin. |

### Caveats

* **`custom_data` is ignored after the VM is created.** This avoids replacing the VM (and its data) whenever a template changes. Template changes (including adding a site) don't reach the running VM: copy the rendered files over by hand, or rebuild with `terraform apply -replace=azurerm_linux_virtual_machine.wp` and restore the sites.
* **Recovery Services vault soft delete** keeps backups for 14 days after deletion, so `terraform destroy` won't fully remove the vault until the soft-deleted items are purged.
* **Managed ruleset IDs** (`efb7b8c9…` Cloudflare Managed, `4814384a…` OWASP) are Cloudflare's published IDs. Check them in the dashboard if Cloudflare changes them.
* **Bot Fight Mode** can block legitimate automation such as uptime monitors and Jetpack. Turn it off per zone if it causes problems.
