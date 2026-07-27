# One storage account, hierarchical namespace enabled (that's what makes
# this ADLS Gen2 rather than plain Blob Storage -- required for Delta Lake's
# atomic rename-based commit protocol). Four containers mirror the AWS
# project's four S3 buckets (staging/raw/curated/enriched) -- same layer
# names, same purpose, no "bronze/silver/gold" naming here either.
resource "azurerm_storage_account" "datalake" {
  name                     = var.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true # hierarchical namespace = ADLS Gen2, not plain Blob
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "layers" {
  for_each              = toset(["staging", "raw", "curated", "enriched"])
  name                  = each.value
  storage_account_name  = azurerm_storage_account.datalake.name
  container_access_type = "private"
}

# Staging's raw ingestion history isn't queried after ~90 days in practice
# (Raw's Delta tables are the durable record) -- mirrors the AWS project's
# S3 Glacier + Lifecycle Archive on staging. Cool after 30d, Archive after
# 90d, matching ADLS Gen2's native tiering (no separate "Glacier" service to
# provision -- it's a policy on the same storage account).
resource "azurerm_storage_management_policy" "staging_lifecycle" {
  storage_account_id = azurerm_storage_account.datalake.id

  rule {
    name    = "staging-archive"
    enabled = true
    filters {
      prefix_match = ["staging/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
      }
    }
  }
}
