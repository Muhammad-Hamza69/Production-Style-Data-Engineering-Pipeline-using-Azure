output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "youtube_api_key_secret_name" {
  value = azurerm_key_vault_secret.youtube_api_key.name
}

output "dashboard_trigger_api_key_secret_name" {
  value = azurerm_key_vault_secret.dashboard_trigger_api_key.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "synapse_sql_admin_password_secret_name" {
  value = azurerm_key_vault_secret.synapse_sql_admin_password.name
}

