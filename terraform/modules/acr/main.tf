# Basic tier: cheapest tier that supports private repos and geo-independent
# pull -- more than enough for 4 low-traffic images. No equivalent of ECR's
# per-repo resources; ACR is one registry, images differentiated by
# repository path within it (yt-ingest, yt-raw-transform, yt-dbt, yt-dashboard).
resource "azurerm_container_registry" "this" {
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false # pods/functions pull via Managed Identity (AcrPull role), not admin creds
}
