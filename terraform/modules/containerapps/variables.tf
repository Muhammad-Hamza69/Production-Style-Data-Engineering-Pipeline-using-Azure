variable "project_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "acr_login_server" { type = string }
variable "storage_account_name" { type = string }
variable "key_vault_uri" { type = string }
variable "youtube_regions" { type = string }
variable "synapse_sql_endpoint" { type = string }
variable "synapse_sql_admin_login" { type = string }
variable "synapse_sql_admin_password" {
  type      = string
  sensitive = true
}
variable "azure_tenant_id" { type = string }
variable "dbt_sp_client_id" { type = string }
variable "dbt_sp_client_secret" {
  type      = string
  sensitive = true
}
variable "logic_app_trigger_url" {
  type    = string
  default = ""
}

variable "ingest_identity_id" { type = string }
variable "ingest_client_id" { type = string }
variable "raw_transform_identity_id" { type = string }
variable "raw_transform_client_id" { type = string }
variable "dbt_identity_id" { type = string }
variable "dbt_client_id" { type = string }
variable "dashboard_identity_id" { type = string }
variable "dashboard_client_id" { type = string }

variable "ingest_image_tag" { type = string }
variable "raw_transform_image_tag" { type = string }
variable "dbt_image_tag" { type = string }
variable "dashboard_image_tag" { type = string }
