# Deliberate deviation from a literal AWS 1:1 port: yt-ingest and
# raw-transform were Lambdas on AWS, which would naively map to Azure
# Functions. Instead, all three ETL steps (ingest, raw-transform, dbt) run
# as Container Apps Jobs in this one environment, alongside the dashboard
# as a regular Container App. One execution model, one consumption billing
# path, no separate Functions hosting plan -- and it means the same
# Docker-image-per-component pattern the AWS project already uses (ECR
# repo per Lambda) carries over unchanged to ACR, instead of splitting
# into "some components are Functions, some are Jobs."

resource "azurerm_container_app_environment" "this" {
  name                       = "${var.project_name}-env"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = var.log_analytics_workspace_id
}

# ── yt-ingest Job ────────────────────────────────────────────────────────
# Manual trigger type: it's started by the Logic App workflow, not on its
# own internal schedule (Logic App's Recurrence trigger is the single
# schedule owner, same "one orchestrator decides when" principle as the
# AWS project's EventBridge -> Step Functions chain).
resource "azurerm_container_app_job" "ingest" {
  name                         = "${var.project_name}-ingest"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  replica_timeout_in_seconds   = 300
  replica_retry_limit          = 0 # fail fast -- the Logic App owns retry/failure semantics

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.ingest_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.ingest_identity_id
  }

  template {
    container {
      name   = "ingest"
      image  = var.ingest_image_tag != "latest" ? "${var.acr_login_server}/yt-ingest:${var.ingest_image_tag}" : "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 0.5
      memory = "1Gi"


      env {
        name  = "STORAGE_ACCOUNT_NAME"
        value = var.storage_account_name
      }
      env {
        name  = "YOUTUBE_REGIONS"
        value = var.youtube_regions
      }
      env {
        name  = "KEY_VAULT_URI"
        value = var.key_vault_uri
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.ingest_client_id
      }
    }
  }
}

# ── raw-transform Job ────────────────────────────────────────────────────
resource "azurerm_container_app_job" "raw_transform" {
  name                         = "${var.project_name}-raw-transform"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 0

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.raw_transform_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.raw_transform_identity_id
  }

  template {
    container {
      name   = "raw-transform"
      image  = var.raw_transform_image_tag != "latest" ? "${var.acr_login_server}/yt-raw-transform:${var.raw_transform_image_tag}" : "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 1.0
      memory = "2Gi"


      env {
        name  = "STORAGE_ACCOUNT_NAME"
        value = var.storage_account_name
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.raw_transform_client_id
      }
    }
  }
}

# ── dbt Job (Curated + Enriched build) ───────────────────────────────────
resource "azurerm_container_app_job" "dbt" {
  name                         = "${var.project_name}-dbt"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  replica_timeout_in_seconds   = 900
  replica_retry_limit          = 0

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.dbt_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.dbt_identity_id
  }

  # Service Principal auth for dbt-synapse's ODBC connection -- see
  # dbt/profiles/profiles.yml.template's header comment for the full "why"
  # (both Managed Identity and SQL auth are confirmed non-viable for this
  # specific adapter/environment combination). synapse-sql-admin-password
  # is unused now but left wired in case a future adapter version restores
  # SQL-auth support.
  secret {
    name  = "synapse-sql-admin-password"
    value = var.synapse_sql_admin_password
  }
  secret {
    name  = "dbt-sp-client-secret"
    value = var.dbt_sp_client_secret
  }

  template {
    container {
      name   = "dbt"
      image  = var.dbt_image_tag != "latest" ? "${var.acr_login_server}/yt-dbt:${var.dbt_image_tag}" : "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 1.0
      memory = "2Gi"


      env {
        name  = "SYNAPSE_SERVER"
        value = var.synapse_sql_endpoint
      }
      env {
        name  = "STORAGE_ACCOUNT_NAME"
        value = var.storage_account_name
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.dbt_client_id
      }
      env {
        name  = "SYNAPSE_SQL_ADMIN_LOGIN"
        value = var.synapse_sql_admin_login
      }
      env {
        name        = "SYNAPSE_SQL_ADMIN_PASSWORD"
        secret_name = "synapse-sql-admin-password"
      }
      env {
        name  = "AZURE_TENANT_ID"
        value = var.azure_tenant_id
      }
      env {
        name  = "DBT_SP_CLIENT_ID"
        value = var.dbt_sp_client_id
      }
      env {
        name        = "DBT_SP_CLIENT_SECRET"
        secret_name = "dbt-sp-client-secret"
      }
    }
  }
}

# ── Dashboard (always-listening, not a Job) ──────────────────────────────
resource "azurerm_container_app" "dashboard" {
  name                         = "${var.project_name}-dashboard"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single" # GitHub Actions pushes a new revision on each deploy -- this IS the GitOps step, no ArgoCD needed

  identity {
    type         = "UserAssigned"
    identity_ids = [var.dashboard_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.dashboard_identity_id
  }

  template {
    min_replicas = 1 # keep 1 warm -- avoids cold-start on every dashboard visit
    max_replicas = 2

    container {
      name   = "dashboard"
      image  = var.dashboard_image_tag != "latest" ? "${var.acr_login_server}/yt-dashboard:${var.dashboard_image_tag}" : "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 0.5
      memory = "1Gi"


      env {
        name  = "SYNAPSE_SERVER"
        value = var.synapse_sql_endpoint
      }
      env {
        name  = "KEY_VAULT_URI"
        value = var.key_vault_uri
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.dashboard_client_id
      }
      env {
        name  = "LOGIC_APP_TRIGGER_URL"
        value = var.logic_app_trigger_url
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}
