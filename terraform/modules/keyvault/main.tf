# One Key Vault does both jobs the AWS side split across two services:
# secret storage (Secrets Manager) and encryption key management (KMS).
# rbac_authorization_enabled = true means access is granted via Azure RBAC
# role assignments (Key Vault Secrets User / Officer), the same
# identity-first model as everything else here -- not the older
# vault-local access-policy list, which doesn't compose with Managed
# Identity as cleanly.
resource "azurerm_key_vault" "this" {
  name                       = var.key_vault_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = false # personal/dev project -- allow immediate purge on teardown
  soft_delete_retention_days = 7
}

# The deploying principal needs Secrets Officer to actually write the
# secrets below in this same apply -- granted first so the resource
# ordering (role assignment -> secret write) doesn't race.
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.deployer_object_id
}

resource "azurerm_key_vault_secret" "youtube_api_key" {
  name         = "youtube-api-key"
  value        = var.youtube_api_key
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_key_vault_secret" "dashboard_trigger_api_key" {
  name         = "dashboard-trigger-api-key"
  value        = var.dashboard_trigger_api_key
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_key_vault_secret" "synapse_sql_admin_password" {
  name         = "synapse-sql-admin-password"
  value        = var.synapse_sql_admin_password
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_secrets_officer]
}
