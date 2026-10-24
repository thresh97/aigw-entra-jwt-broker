output "resource_group" {
  value = local.rg.name
}

output "container_app_name" {
  value = try(azurerm_container_app.broker[0].name, null)
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "jwks_url" {
  description = "Paste this into the Portkey organisation's JWKS URL setting. Null until the second pass creates the app."
  value       = try("https://${azurerm_container_app.broker[0].ingress[0].fqdn}/.well-known/jwks.json", null)
}

output "exchange_url" {
  value = try("https://${azurerm_container_app.broker[0].ingress[0].fqdn}/token/exchange", null)
}
