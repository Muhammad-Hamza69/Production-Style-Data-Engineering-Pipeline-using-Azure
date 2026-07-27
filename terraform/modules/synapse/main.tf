# Synapse workspace, not Microsoft Fabric -- Fabric needs a paid capacity
# (F2 minimum, ~$262/mo if left running) with zero idle-cost option short of
# pausing it manually. Synapse's serverless SQL pool has NO capacity to
# provision at all: it's billed per-TB-scanned, exactly like Athena, and is
# available the instant the workspace exists. This workspace itself creates
# a small ADLS Gen2 account for Synapse's own metadata (separate from the
# project's data-lake storage account) plus a "logical SQL server" under the
# hood -- confirmed via CLI testing that this can be blocked in some regions
# on new subscriptions (SqlServerRegionDoesNotAllowProvisioning); centralus
# is confirmed clear.
resource "azurerm_storage_account" "synapse_fs" {
  name                     = var.synapse_storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true
}

resource "azurerm_storage_data_lake_gen2_filesystem" "synapse_fs" {
  name               = "synapsefs"
  storage_account_id = azurerm_storage_account.synapse_fs.id
}

resource "azurerm_synapse_workspace" "this" {
  name                                 = var.workspace_name
  resource_group_name                  = var.resource_group_name
  location                             = var.location
  storage_data_lake_gen2_filesystem_id = azurerm_storage_data_lake_gen2_filesystem.synapse_fs.id
  sql_administrator_login              = var.sql_admin_login
  sql_administrator_login_password     = var.sql_admin_password

  identity {
    type = "SystemAssigned"
  }
}

# Serverless SQL pool ("Built-in") exists automatically on every workspace
# with no separate resource to create/pay for -- there is deliberately no
# azurerm_synapse_sql_pool resource here, since that resource type
# provisions the DEDICATED (always-on, billed-by-the-hour) pool, which is
# exactly the fixed-cost trap this whole redesign is avoiding. Databases and
# external tables inside the serverless "Built-in" pool are created via SQL
# script (see scripts/synapse_setup.sql), not Terraform -- same reasoning
# as the AWS project's QuickSight dashboard JSON: this is schema content,
# not infrastructure, and iterates faster against the SQL endpoint directly.

# Allow Azure services (Container Apps, the dashboard) to reach the
# workspace's SQL endpoint without a private-endpoint/VNet setup -- fine for
# a project this size; tighten to a specific outbound IP range if this ever
# needs to be more locked down.
# CREATE DATABASE SCOPED CREDENTIAL ... WITH IDENTITY = 'Managed Identity'
# (scripts/synapse_setup.sql) authenticates as the WORKSPACE's own
# system-assigned identity, not the calling user/pod's identity -- easy to
# miss since every other credential in this project is a per-component
# user-assigned identity. Confirmed against a real query failure ("Content
# of directory ... cannot be listed") that only surfaced when actually
# reading data, not at CREATE EXTERNAL TABLE time (DDL doesn't validate
# underlying file access).
resource "azurerm_role_assignment" "workspace_identity_storage_access" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_synapse_workspace.this.identity[0].principal_id
}

resource "azurerm_synapse_firewall_rule" "allow_azure_services" {
  name                 = "AllowAllWindowsAzureIps"
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  start_ip_address     = "0.0.0.0"
  end_ip_address       = "0.0.0.0"
}

# The 0.0.0.0-0.0.0.0 "AllowAllWindowsAzureIps" rule above only covers
# Azure-hosted callers -- it does NOT cover arbitrary public IPs, which is
# what a locally-run `terraform apply` is. azurerm_synapse_role_assignment
# calls a REST API hosted at the workspace's own endpoint, gated by these
# SAME firewall rules -- confirmed against a real apply failure
# (ClientIpAddressNotAuthorized) that only surfaced on the role-assignment
# resources, not the workspace/firewall-rule resources created earlier in
# the same apply. Whoever runs `terraform apply` locally needs their own
# public IP allowlisted here.
resource "azurerm_synapse_firewall_rule" "allow_deployer_ip" {
  name                 = "AllowDeployerIp"
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  start_ip_address     = var.deployer_ip_address
  end_ip_address       = var.deployer_ip_address
}

# These are Synapse's OWN internal RBAC roles (granted via Synapse's own
# permission API, exposed through azurerm_synapse_role_assignment) -- NOT
# standard Azure/Microsoft.Authorization roles, which is why the earlier
# attempt using azurerm_role_assignment failed with "could not find role":
# these role names simply don't exist in that namespace at all, regardless
# of spelling. "Synapse SQL Administrator" gives the dbt job full
# read/write over the SQL surface (needed for CREATE EXTERNAL TABLE, GRANT,
# etc. in scripts/synapse_setup.sql); "Synapse User" is read-only, for the
# dashboard.
resource "azurerm_synapse_role_assignment" "dbt_synapse_sql_admin" {
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  role_name            = "Synapse SQL Administrator"
  principal_id         = var.dbt_principal_id
  depends_on           = [azurerm_synapse_firewall_rule.allow_deployer_ip]
}

resource "azurerm_synapse_role_assignment" "dashboard_synapse_user" {
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  role_name            = "Synapse User"
  principal_id         = var.dashboard_principal_id
  depends_on           = [azurerm_synapse_firewall_rule.allow_deployer_ip]
}
