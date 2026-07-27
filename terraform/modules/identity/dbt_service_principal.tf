# A real Azure AD Service Principal, not a Managed Identity -- the one
# deliberate exception to this project's "identity, not secret" pattern.
# Forced by two stacked, confirmed platform/adapter limitations:
#   1. The ODBC driver's native Authentication=ActiveDirectoryMsi handling
#      only understands the classic Azure VM instance-metadata endpoint
#      (169.254.169.254); Container Apps exposes identity via an
#      App-Service-style local endpoint instead, so MSI auth just hangs
#      and times out ("Login timeout expired (SQLDriverConnect)").
#   2. dbt-synapse==1.8.0 internally reuses dbt-fabric's connection
#      manager, which hard-blocks plain SQL authentication outright
#      ("SQL Authentication is not supported by Microsoft Fabric").
# A Service Principal's client-credentials OAuth flow needs neither
# instance metadata nor SQL auth, so it's the one AAD auth mode left that
# actually works from inside a Container Apps Job for this adapter.
resource "azuread_application" "dbt_synapse" {
  display_name = "yt-pipeline-dbt-sp"
}

resource "azuread_service_principal" "dbt_synapse" {
  client_id = azuread_application.dbt_synapse.client_id
}

resource "azuread_application_password" "dbt_synapse" {
  application_id    = azuread_application.dbt_synapse.id
  end_date_relative = "8760h" # 1 year
}
