output "storage_account_id" {
  value = azurerm_storage_account.datalake.id
}

output "storage_account_name" {
  value = azurerm_storage_account.datalake.name
}

output "primary_dfs_endpoint" {
  value = azurerm_storage_account.datalake.primary_dfs_endpoint
}

output "container_names" {
  value = { for k, v in azurerm_storage_container.layers : k => v.name }
}
