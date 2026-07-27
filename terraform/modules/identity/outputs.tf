output "ingest_identity_id" {
  value = azurerm_user_assigned_identity.ingest.id
}
output "ingest_principal_id" {
  value = azurerm_user_assigned_identity.ingest.principal_id
}
output "ingest_client_id" {
  value = azurerm_user_assigned_identity.ingest.client_id
}

output "raw_transform_identity_id" {
  value = azurerm_user_assigned_identity.raw_transform.id
}
output "raw_transform_principal_id" {
  value = azurerm_user_assigned_identity.raw_transform.principal_id
}
output "raw_transform_client_id" {
  value = azurerm_user_assigned_identity.raw_transform.client_id
}

output "dbt_identity_id" {
  value = azurerm_user_assigned_identity.dbt.id
}
output "dbt_principal_id" {
  value = azurerm_user_assigned_identity.dbt.principal_id
}
output "dbt_client_id" {
  value = azurerm_user_assigned_identity.dbt.client_id
}

output "dashboard_identity_id" {
  value = azurerm_user_assigned_identity.dashboard.id
}
output "dashboard_principal_id" {
  value = azurerm_user_assigned_identity.dashboard.principal_id
}
output "dashboard_client_id" {
  value = azurerm_user_assigned_identity.dashboard.client_id
}

output "logicapp_identity_id" {
  value = azurerm_user_assigned_identity.logicapp.id
}
output "logicapp_principal_id" {
  value = azurerm_user_assigned_identity.logicapp.principal_id
}
output "logicapp_client_id" {
  value = azurerm_user_assigned_identity.logicapp.client_id
}

output "dbt_sp_client_id" {
  value = azuread_application.dbt_synapse.client_id
}
output "dbt_sp_client_secret" {
  value     = azuread_application_password.dbt_synapse.value
  sensitive = true
}
output "dbt_sp_object_id" {
  value = azuread_service_principal.dbt_synapse.object_id
}
