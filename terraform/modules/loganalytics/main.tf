# Azure Monitor Activity Log is free/automatic at the subscription level --
# nothing to provision for that. This workspace is the CloudTrail-adjacent
# piece that actually costs something: it's where Container Apps stdout/
# stderr, Function App logs, and (optionally) exported Activity Log entries
# land so they're queryable instead of ephemeral. Free tier: 5GB/mo
# ingestion, 30-day retention -- plenty for this project's volume.
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.project_name}-logs"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}
