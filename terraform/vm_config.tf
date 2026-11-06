# Renders the cloud-init payload that turns a stock Ubuntu VM into the
# WordPress host: Docker, one WordPress + MariaDB pair per site, and cloudflared.

locals {
  site_keys = sort(keys(var.sites))

  vm_files = {
    "/opt/wordpress/docker-compose.yml" = {
      permissions = "0644"
      content = templatefile("${path.module}/templates/docker-compose.yml.tftpl", {
        site_keys         = local.site_keys
        wordpress_image   = var.wordpress_image
        mariadb_image     = var.mariadb_image
        cloudflared_image = var.cloudflared_image
      })
    }
    "/opt/wordpress/config/wp-config-extra.php" = {
      permissions = "0644"
      content     = file("${path.module}/templates/wp-config-extra.php")
    }
    "/opt/wordpress/config/php-overrides.ini" = {
      permissions = "0644"
      content     = file("${path.module}/templates/php-overrides.ini")
    }
    "/opt/wordpress/config/mpm_prefork.conf" = {
      permissions = "0644"
      content     = file("${path.module}/templates/mpm_prefork.conf")
    }
    "/opt/wordpress/bin/install-docker.sh" = {
      permissions = "0750"
      content     = file("${path.module}/templates/install-docker.sh")
    }
    "/opt/wordpress/bin/prepare-secrets.sh" = {
      permissions = "0750"
      content = templatefile("${path.module}/templates/prepare-secrets.sh.tftpl", {
        site_keys      = local.site_keys
        key_vault_name = azurerm_key_vault.wp.name
        secret_name    = local.tunnel_secret_name
      })
    }
    "/opt/wordpress/bin/backup-db.sh" = {
      permissions = "0750"
      content = templatefile("${path.module}/templates/backup-db.sh.tftpl", {
        site_keys = local.site_keys
      })
    }
    "/etc/systemd/system/wordpress-stack.service" = {
      permissions = "0644"
      content     = file("${path.module}/templates/wordpress-stack.service")
    }
    "/etc/cron.d/wordpress" = {
      permissions = "0644"
      content = templatefile("${path.module}/templates/wordpress.cron.tftpl", {
        site_keys = local.site_keys
      })
    }
    "/etc/apt/apt.conf.d/20auto-upgrades" = {
      permissions = "0644"
      content     = <<-EOT
        APT::Periodic::Update-Package-Lists "1";
        APT::Periodic::Unattended-Upgrade "1";
        APT::Periodic::AutocleanInterval "7";
      EOT
    }
    "/etc/apt/apt.conf.d/52unattended-wordpress" = {
      permissions = "0644"
      content     = <<-EOT
        Unattended-Upgrade::Origins-Pattern { "origin=Docker"; };
        Unattended-Upgrade::Automatic-Reboot "true";
        Unattended-Upgrade::Automatic-Reboot-Time "08:30";
      EOT
    }
  }

  cloud_init = "#cloud-config\n${yamlencode({
    package_update  = true
    package_upgrade = true
    packages        = ["ca-certificates", "curl", "jq", "openssl", "unattended-upgrades"]
    swap = {
      filename = "/swapfile"
      size     = "2G"
    }
    write_files = [
      for path in sort(keys(local.vm_files)) : {
        path        = path
        permissions = local.vm_files[path].permissions
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.vm_files[path].content)
      }
    ]
    runcmd = [
      ["bash", "/opt/wordpress/bin/install-docker.sh"],
      ["systemctl", "daemon-reload"],
      ["systemctl", "enable", "--now", "wordpress-stack.service"],
    ]
  })}"
}
