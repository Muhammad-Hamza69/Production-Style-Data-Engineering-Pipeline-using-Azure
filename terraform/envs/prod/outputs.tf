output "storage_account_name" {
  value = module.storage.storage_account_name
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "key_vault_uri" {
  value = module.keyvault.vault_uri
}

output "synapse_sql_endpoint" {
  value = module.synapse.sql_endpoint
}

output "dashboard_fqdn" {
  value = module.containerapps.dashboard_fqdn
}

output "logic_app_workflow_name" {
  value = module.logicapp.workflow_name
}

output "gmail_connection_id" {
  value = module.logicapp.gmail_connection_id
}

output "ingest_job_name" {
  value = module.containerapps.ingest_job_name
}
output "raw_transform_job_name" {
  value = module.containerapps.raw_transform_job_name
}
output "dbt_job_name" {
  value = module.containerapps.dbt_job_name
}

output "resource_group_name" {
  value = var.resource_group_name
}

