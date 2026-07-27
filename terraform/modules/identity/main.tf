# One User-Assigned Managed Identity per compute component -- direct analog
# of the AWS project's per-Lambda IAM role / per-pod IRSA role pattern.
# Functions and Container Apps both support attaching a UAMI natively, so
# there's no equivalent of IRSA's OIDC-federation plumbing to stand up --
# "assign this identity to this compute resource" is the whole mechanism.

resource "azurerm_user_assigned_identity" "ingest" {
  name                = "${var.project_name}-ingest-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_user_assigned_identity" "raw_transform" {
  name                = "${var.project_name}-raw-transform-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_user_assigned_identity" "dbt" {
  name                = "${var.project_name}-dbt-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_user_assigned_identity" "dashboard" {
  name                = "${var.project_name}-dashboard-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_user_assigned_identity" "logicapp" {
  name                = "${var.project_name}-logicapp-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# ── Storage RBAC ─────────────────────────────────────────────────────────
# "Storage Blob Data Contributor/Reader" scoped to the whole storage
# account (container-level scoping exists but needs each container's full
# resource ID; account-level keeps this readable -- tightening to
# per-container is a straightforward follow-up, not a blocker, since
# Iceberg-equivalent Delta writes don't cross container boundaries anyway).

resource "azurerm_role_assignment" "ingest_staging_write" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ingest.principal_id
}

resource "azurerm_role_assignment" "raw_transform_storage" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.raw_transform.principal_id
}

resource "azurerm_role_assignment" "dbt_storage" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.dbt.principal_id
}

resource "azurerm_role_assignment" "dashboard_storage_read" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.dashboard.principal_id
}

# ── Key Vault RBAC ───────────────────────────────────────────────────────

resource "azurerm_role_assignment" "ingest_kv_read" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.ingest.principal_id
}

resource "azurerm_role_assignment" "dashboard_kv_read" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.dashboard.principal_id
}

resource "azurerm_role_assignment" "logicapp_kv_read" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.logicapp.principal_id
}

# ── ACR pull ─────────────────────────────────────────────────────────────
# Every compute component that pulls a container image needs AcrPull --
# Functions here are container-based (matching the AWS project's
# Docker-image Lambdas), not zip-deploy.

resource "azurerm_role_assignment" "ingest_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.ingest.principal_id
}

resource "azurerm_role_assignment" "raw_transform_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.raw_transform.principal_id
}

resource "azurerm_role_assignment" "dbt_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.dbt.principal_id
}

resource "azurerm_role_assignment" "dashboard_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.dashboard.principal_id
}

# NOTE: the Logic App -> "start the dbt Container Apps Job" role assignment
# (the Azure-native replacement for the AWS project's dbt_trigger Lambda's
# whole Kubernetes-bearer-token auth block -- here it's just a plain RBAC
# role letting the Logic App's identity call the Jobs REST API) is defined
# in the ROOT module, not here: it needs this module's logicapp identity
# AND the containerapps module's dbt job ID, and those two modules can't
# depend on each other without a cycle. Root is where both already exist.
