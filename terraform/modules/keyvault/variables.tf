variable "key_vault_name" {
  description = "Globally unique, 3-24 alphanumeric/hyphen chars."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "deployer_object_id" {
  description = "Object ID of the identity running terraform apply -- needs Secrets Officer to write the secrets below in this same apply."
  type        = string
}

variable "youtube_api_key" {
  type      = string
  sensitive = true
}

variable "dashboard_trigger_api_key" {
  type      = string
  sensitive = true
}

variable "synapse_sql_admin_password" {
  type      = string
  sensitive = true
}
