output "workflow_id" {
  value = azurerm_logic_app_workflow.this.id
}

output "workflow_name" {
  value = azurerm_logic_app_workflow.this.name
}

output "gmail_connection_id" {
  description = "Needs a one-time manual Authorize click in the Azure Portal after first apply (sign in with the Gmail alert account)."
  value       = azurerm_api_connection.gmail.id
}
