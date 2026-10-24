terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      purge_soft_deleted_keys_on_destroy = true
      purge_soft_delete_on_destroy       = true
      recover_soft_deleted_key_vaults    = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
