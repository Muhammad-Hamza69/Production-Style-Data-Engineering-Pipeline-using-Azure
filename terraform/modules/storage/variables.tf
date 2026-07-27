variable "storage_account_name" {
  description = "Globally unique, 3-24 lowercase alphanumeric chars, no hyphens."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}
