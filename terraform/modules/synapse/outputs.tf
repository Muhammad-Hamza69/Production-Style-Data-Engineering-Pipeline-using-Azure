output "workspace_id" {
  value = azurerm_synapse_workspace.this.id
}

output "sql_endpoint" {
  description = "Serverless (Built-in) SQL pool endpoint -- <workspace>-ondemand.sql.azuresynapse.net"
  value       = azurerm_synapse_workspace.this.connectivity_endpoints["sqlOnDemand"]
}

output "workspace_name" {
  value = azurerm_synapse_workspace.this.name
}
