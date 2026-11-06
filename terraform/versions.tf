terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Partial configuration: values are supplied with -backend-config
  # (see environments/backend.hcl.example and the GitHub workflow).
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
  # subscription_id / tenant_id / client_id come from ARM_* environment variables.
}

# API token comes from the CLOUDFLARE_API_TOKEN environment variable.
provider "cloudflare" {}
