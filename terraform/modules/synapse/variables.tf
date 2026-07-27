variable "workspace_name" {
  description = "Globally unique, 1-50 lowercase alphanumeric/hyphen chars."
  type        = string
}

variable "synapse_storage_account_name" {
  description = "Globally unique, 3-24 lowercase alphanumeric chars. Separate from the project's data-lake account -- this one holds only Synapse's own workspace metadata."
  type        = string
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "sql_admin_login" {
  type    = string
  default = "synadmin"
}

variable "sql_admin_password" {
  type      = string
  sensitive = true
}

variable "dbt_principal_id" { type = string }
variable "dashboard_principal_id" { type = string }

variable "storage_account_id" {
  description = "The project's data-lake storage account -- the workspace's own system-assigned identity needs Storage Blob Data Contributor here for CREATE DATABASE SCOPED CREDENTIAL ... WITH IDENTITY = 'Managed Identity' to actually read Delta files."
  type        = string
}

variable "deployer_ip_address" {
  description = "Public IP of whoever runs terraform apply -- Synapse's role-assignment management API has its own firewall, separate from the SQL data-plane firewall rule."
  type        = string
}
