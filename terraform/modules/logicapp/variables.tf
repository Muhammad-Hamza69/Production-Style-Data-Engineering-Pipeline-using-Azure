variable "project_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "logicapp_identity_id" { type = string }
variable "workflow_definition_json" {
  description = "Rendered contents of pipeline_workflow.json.tftpl"
  type        = string
}
variable "notifier_definition_json" {
  description = "Rendered contents of notifier_workflow.json.tftpl"
  type        = string
  default     = ""
}

