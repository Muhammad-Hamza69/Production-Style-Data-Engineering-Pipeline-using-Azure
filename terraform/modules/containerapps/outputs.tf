output "environment_id" {
  value = azurerm_container_app_environment.this.id
}

output "ingest_job_id" {
  value = azurerm_container_app_job.ingest.id
}
output "ingest_job_name" {
  value = azurerm_container_app_job.ingest.name
}

output "raw_transform_job_id" {
  value = azurerm_container_app_job.raw_transform.id
}
output "raw_transform_job_name" {
  value = azurerm_container_app_job.raw_transform.name
}

output "dbt_job_id" {
  value = azurerm_container_app_job.dbt.id
}
output "dbt_job_name" {
  value = azurerm_container_app_job.dbt.name
}

output "dashboard_app_id" {
  value = azurerm_container_app.dashboard.id
}
output "dashboard_fqdn" {
  value = azurerm_container_app.dashboard.ingress[0].fqdn
}
