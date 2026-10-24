data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  base = "${var.name_prefix}${random_string.suffix.result}"
  tags = merge({ purpose = "aigw-entra-jwt-broker" }, var.tags)

  # Stored without nulls so the app setting stays small and readable.
  policy_json = jsonencode({
    for role, p in var.policy : role => merge(
      { workspace = p.workspace, config_slug = p.config_slug, scopes = p.scopes },
      p.config_id == null ? {} : { config_id = p.config_id },
      p.metadata == null ? {} : { metadata = p.metadata },
      p.usage_limits == null ? {} : { usage_limits = p.usage_limits },
    )
  })
}

# Creates its own resource group unless one is supplied (for example one where the deployer already holds
# User Access Administrator, so the role assignments below are allowed).
resource "azurerm_resource_group" "created" {
  count    = var.resource_group_name == null ? 1 : 0
  name     = "rg-${local.base}"
  location = var.location
  tags     = local.tags
}

data "azurerm_resource_group" "given" {
  count = var.resource_group_name == null ? 0 : 1
  name  = var.resource_group_name
}

locals {
  rg = var.resource_group_name == null ? {
    name = azurerm_resource_group.created[0].name, location = azurerm_resource_group.created[0].location
    } : {
    name = data.azurerm_resource_group.given[0].name, location = data.azurerm_resource_group.given[0].location
  }
}

resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.base}"
  resource_group_name        = local.rg.name
  location                   = local.rg.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = local.tags
}

# Lets the account running Terraform create the key. The broker identity only gets sign and read rights below.
resource "azurerm_role_assignment" "deployer_crypto_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Fixed wait: Azure RBAC grants are eventually consistent and the key create below fails if it runs first.
resource "time_sleep" "rbac" {
  depends_on      = [azurerm_role_assignment.deployer_crypto_officer]
  create_duration = "60s"
}

resource "azurerm_key_vault_key" "signing" {
  name         = "portkey-signing-key"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["sign", "verify"]

  depends_on = [time_sleep.rbac]
}

# User-assigned identity for signing with the key. It exists before the app does, so the role assignment is in place
# when the first revision starts. The image comes from a public registry, so no pull credential is needed.
resource "azurerm_user_assigned_identity" "broker" {
  name                = "id-${local.base}"
  resource_group_name = local.rg.name
  location            = local.rg.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "broker_crypto_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.broker.principal_id
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.base}"
  resource_group_name = local.rg.name
  location            = local.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.base}"
  resource_group_name        = local.rg.name
  location                   = local.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags
}

# Created in the second pass, once the image is published (var.container_image is set).
resource "azurerm_container_app" "broker" {
  count                        = var.container_image == null ? 0 : 1
  name                         = "ca-${local.base}"
  resource_group_name          = local.rg.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.broker.id]
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 2

    container {
      name   = "broker"
      image  = var.container_image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.broker.client_id
      }
      env {
        name  = "KEY_VAULT_URL"
        value = azurerm_key_vault.this.vault_uri
      }
      env {
        name  = "KEY_NAME"
        value = azurerm_key_vault_key.signing.name
      }
      env {
        name  = "ENTRA_TENANT_ID"
        value = var.entra_tenant_id
      }
      env {
        name  = "ENTRA_CLIENT_ID"
        value = var.entra_client_id
      }
      env {
        name  = "ENTRA_APP_ID_URI"
        value = var.entra_app_id_uri
      }
      env {
        name  = "PORTKEY_ORG_ID"
        value = var.portkey_oid
      }
      env {
        name  = "POLICY_JSON"
        value = local.policy_json
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/healthz"
      }
    }
  }

  depends_on = [azurerm_role_assignment.broker_crypto_user]
}
