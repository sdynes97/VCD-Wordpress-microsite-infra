data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "wp" {
  name = var.resource_group_name
}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

# ---------------------------------------------------------------------------
# Network: no inbound from the internet. Web traffic arrives through an
# outbound-only Cloudflare Tunnel; the public IP exists only for egress
# (and optional SSH from ssh_allowed_cidrs).
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "wp" {
  name                = "vnet-${var.name_prefix}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.wp.name
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "wp" {
  name                 = "snet-${var.name_prefix}"
  resource_group_name  = data.azurerm_resource_group.wp.name
  virtual_network_name = azurerm_virtual_network.wp.name
  address_prefixes     = [var.subnet_prefix]
}

resource "azurerm_network_security_group" "wp" {
  name                = "nsg-${var.name_prefix}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.wp.name
  tags                = var.tags

  dynamic "security_rule" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      name                       = "Allow-SSH-Admin"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = var.ssh_allowed_cidrs
      destination_address_prefix = "*"
    }
  }

  # Explicit deny so intent is obvious (the platform default also denies).
  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "wp" {
  subnet_id                 = azurerm_subnet.wp.id
  network_security_group_id = azurerm_network_security_group.wp.id
}

resource "azurerm_public_ip" "wp" {
  name                = "pip-${var.name_prefix}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.wp.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "wp" {
  name                = "nic-${var.name_prefix}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.wp.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.wp.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.wp.id
  }
}

# ---------------------------------------------------------------------------
# Key Vault: holds the Cloudflare Tunnel token. The VM reads it at boot via
# its managed identity, so the token is never baked into custom data.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "wp" {
  name                       = "kv-${var.name_prefix}-${random_string.suffix.result}"
  location                   = local.location
  resource_group_name        = data.azurerm_resource_group.wp.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = var.tags
}

resource "azurerm_key_vault_secret" "tunnel_token" {
  name         = local.tunnel_secret_name
  value        = data.cloudflare_zero_trust_tunnel_cloudflared_token.wp.token
  key_vault_id = azurerm_key_vault.wp.id
  content_type = "cloudflared tunnel token"
}

# ---------------------------------------------------------------------------
# VM
# ---------------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "wp" {
  name                            = "vm-${var.name_prefix}"
  location                        = local.location
  resource_group_name             = data.azurerm_resource_group.wp.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.wp.id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  custom_data                     = base64encode(local.cloud_init)
  tags                            = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    name                 = "osdisk-${var.name_prefix}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {}

  lifecycle {
    # custom_data forces VM replacement; the VM holds the site data, so changes
    # to cloud-init are applied to a NEW VM only (taint deliberately if needed).
    ignore_changes = [custom_data]
  }
}

resource "azurerm_role_assignment" "vm_kv_secrets_user" {
  scope                = azurerm_key_vault.wp.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.wp.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Backups: daily VM snapshot (Enhanced policy is required for Trusted Launch).
# Nightly mysqldumps on the VM give app-consistent DB copies inside each snapshot.
# ---------------------------------------------------------------------------

resource "azurerm_recovery_services_vault" "wp" {
  name                = "rsv-${var.name_prefix}"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.wp.name
  sku                 = "Standard"
  storage_mode_type   = "LocallyRedundant"
  tags                = var.tags
}

resource "azurerm_backup_policy_vm" "daily" {
  name                = "daily-${var.backup_retention_days}d"
  resource_group_name = data.azurerm_resource_group.wp.name
  recovery_vault_name = azurerm_recovery_services_vault.wp.name
  policy_type         = "V2"
  timezone            = "UTC"

  backup {
    frequency = "Daily"
    time      = var.backup_time_utc
  }

  retention_daily {
    count = var.backup_retention_days
  }
}

resource "azurerm_backup_protected_vm" "wp" {
  resource_group_name = data.azurerm_resource_group.wp.name
  recovery_vault_name = azurerm_recovery_services_vault.wp.name
  source_vm_id        = azurerm_linux_virtual_machine.wp.id
  backup_policy_id    = azurerm_backup_policy_vm.daily.id
}
