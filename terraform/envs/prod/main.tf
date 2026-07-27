locals {
  # Storage/ACR/Key Vault/Synapse account names must be globally unique
  # across all of Azure and follow tight character-set rules per resource
  # type -- suffixing with the subscription ID's first 8 chars keeps names
  # deterministic across re-applies without colliding with anyone else's.
  suffix = substr(data.azurerm_client_config.current.subscription_id, 0, 8)

  # Predictable Azure resource ID for the Logic App, computed as a plain
  # string rather than referenced from module.logicapp's output -- the
  # dashboard (inside module.containerapps) needs this URL to manually
  # trigger a run, but module.logicapp itself depends on
  # module.containerapps' job IDs (its workflow definition embeds them).
  # A real attribute reference either direction would be a dependency
  # cycle; a same-string computed independently on both sides isn't.
  logic_app_workflow_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Logic/workflows/${var.project_name}-orchestration"
  logic_app_trigger_url = "https://management.azure.com${local.logic_app_workflow_id}/triggers/Hourly/run?api-version=2019-05-01"
  synapse_password      = random_password.synapse_admin_password.result
}


module "loganalytics" {
  source              = "../../modules/loganalytics"
  project_name        = var.project_name
  resource_group_name = var.resource_group_name
  location            = var.location
}

module "storage" {
  source               = "../../modules/storage"
  storage_account_name = "ytpipeline${local.suffix}"
  resource_group_name  = var.resource_group_name
  location             = var.location
}

module "acr" {
  source              = "../../modules/acr"
  registry_name       = "ytpipeline${local.suffix}acr"
  resource_group_name = var.resource_group_name
  location            = var.location
}

module "keyvault" {
  source                     = "../../modules/keyvault"
  key_vault_name             = "ytpl-kv-${local.suffix}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  deployer_object_id         = data.azurerm_client_config.current.object_id
  youtube_api_key            = var.youtube_api_key
  dashboard_trigger_api_key  = random_password.dashboard_trigger_api_key.result
  synapse_sql_admin_password = local.synapse_password
}

resource "random_password" "dashboard_trigger_api_key" {
  length  = 32
  special = false
}

resource "random_password" "synapse_admin_password" {
  length           = 24
  special          = true
  override_special = "!@#$"
}

module "identity" {
  source              = "../../modules/identity"
  project_name        = var.project_name
  resource_group_name = var.resource_group_name
  location            = var.location
  storage_account_id  = module.storage.storage_account_id
  key_vault_id        = module.keyvault.key_vault_id
  acr_id              = module.acr.registry_id
}

module "synapse" {
  source                       = "../../modules/synapse"
  workspace_name               = "ytpl-synapse-${local.suffix}"
  synapse_storage_account_name = "ytplsynfs${local.suffix}"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  sql_admin_password           = local.synapse_password
  dbt_principal_id             = module.identity.dbt_principal_id
  dashboard_principal_id       = module.identity.dashboard_principal_id
  deployer_ip_address          = var.deployer_ip_address
  storage_account_id           = module.storage.storage_account_id
}

module "containerapps" {
  source                     = "../../modules/containerapps"
  project_name               = var.project_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = module.loganalytics.workspace_id
  acr_login_server           = module.acr.login_server
  storage_account_name       = module.storage.storage_account_name
  key_vault_uri              = module.keyvault.vault_uri
  youtube_regions            = var.youtube_regions
  synapse_sql_endpoint       = module.synapse.sql_endpoint
  synapse_sql_admin_login    = "synadmin"
  synapse_sql_admin_password = local.synapse_password

  azure_tenant_id      = data.azurerm_client_config.current.tenant_id
  dbt_sp_client_id     = module.identity.dbt_sp_client_id
  dbt_sp_client_secret = module.identity.dbt_sp_client_secret

  ingest_identity_id        = module.identity.ingest_identity_id
  ingest_client_id          = module.identity.ingest_client_id
  raw_transform_identity_id = module.identity.raw_transform_identity_id
  raw_transform_client_id   = module.identity.raw_transform_client_id
  dbt_identity_id           = module.identity.dbt_identity_id
  dbt_client_id             = module.identity.dbt_client_id
  dashboard_identity_id     = module.identity.dashboard_identity_id
  dashboard_client_id       = module.identity.dashboard_client_id

  ingest_image_tag        = var.ingest_image_tag
  raw_transform_image_tag = var.raw_transform_image_tag
  dbt_image_tag           = var.dbt_image_tag
  dashboard_image_tag     = var.dashboard_image_tag

  logic_app_trigger_url = local.logic_app_trigger_url
}

# Least-privilege role covering Microsoft.Logic/workflows/triggers/run/action
# -- lets the dashboard fire a manual pipeline run without granting it
# Contributor on the whole workflow (which would also let it edit the
# workflow definition, not just run it).
resource "azurerm_role_assignment" "dashboard_run_logic_app" {
  scope                = data.azurerm_resource_group.this.id
  role_definition_name = "Logic App Operator"
  principal_id         = module.identity.dashboard_principal_id
}


# Logic App's identity needs Contributor on each Job it starts -- defined
# here, not inside modules/identity, because it needs both that module's
# identity AND this module's job IDs (see identity module's note on why
# this specific assignment can't live in either module without a cycle).
resource "azurerm_role_assignment" "logicapp_run_ingest_job" {
  scope                = module.containerapps.ingest_job_id
  role_definition_name = "Contributor"
  principal_id         = module.identity.logicapp_principal_id
}

resource "azurerm_role_assignment" "logicapp_run_raw_transform_job" {
  scope                = module.containerapps.raw_transform_job_id
  role_definition_name = "Contributor"
  principal_id         = module.identity.logicapp_principal_id
}

resource "azurerm_role_assignment" "logicapp_run_dbt_job" {
  scope                = module.containerapps.dbt_job_id
  role_definition_name = "Contributor"
  principal_id         = module.identity.logicapp_principal_id
}

module "logicapp" {
  source               = "../../modules/logicapp"
  project_name         = var.project_name
  resource_group_name  = var.resource_group_name
  location             = var.location
  logicapp_identity_id = module.identity.logicapp_identity_id
  workflow_definition_json = templatefile("${path.module}/../../templates/pipeline_workflow.json.tftpl", {
    ingest_job_id        = module.containerapps.ingest_job_id
    raw_transform_job_id = module.containerapps.raw_transform_job_id
    dbt_job_id           = module.containerapps.dbt_job_id
    alert_email          = var.alert_email
  })
  notifier_definition_json = templatefile("${path.module}/../../templates/notifier_workflow.json.tftpl", {})
}

