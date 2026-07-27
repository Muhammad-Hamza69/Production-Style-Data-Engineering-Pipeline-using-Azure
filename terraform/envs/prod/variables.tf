variable "resource_group_name" {
  description = "Pre-existing resource group everything in this project lives under (created once, out of band, by the operator: az group create --name HAMZA-RESOURCE-GROUP)."
  type        = string
  default     = "HAMZA-RESOURCE-GROUP"
}

variable "location" {
  description = "Azure region. centralus, not eastus -- new subscriptions can hit SqlServerRegionDoesNotAllowProvisioning in eastus, which blocks the Synapse workspace (it provisions a logical SQL server under the hood). Confirmed working in centralus."
  type        = string
  default     = "centralus"
}

variable "project_name" {
  type    = string
  default = "yt-pipeline"
}

variable "youtube_api_key" {
  description = "YouTube Data API v3 key. Passed via -var, never committed."
  type        = string
  sensitive   = true
}

variable "alert_email" {
  type = string
}

variable "deployer_ip_address" {
  description = "Public IP of whoever runs terraform apply, for Synapse's role-assignment firewall."
  type        = string
  default     = "0.0.0.0"
}

variable "synapse_sql_admin_password" {
  description = "Admin password for the Synapse workspace's built-in SQL pool login."
  type        = string
  sensitive   = true
  default     = "ytP!peL1ne2026#SecureAdmin"
}


variable "ingest_image_tag" {
  type    = string
  default = "latest"
}

variable "raw_transform_image_tag" {
  type    = string
  default = "latest"
}

variable "dbt_image_tag" {
  type    = string
  default = "latest"
}

variable "dashboard_image_tag" {
  type    = string
  default = "latest"
}


variable "youtube_regions" {
  type    = string
  default = "US,GB,CA,DE,FR,IN,JP,KR,MX,RU"
}
