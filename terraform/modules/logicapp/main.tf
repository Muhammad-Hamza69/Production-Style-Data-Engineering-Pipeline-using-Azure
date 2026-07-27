# The AWS project's EventBridge (hourly trigger) + Step Functions (Task/
# Catch state machine) collapse into ONE resource here: a Logic App is
# trigger + workflow together. See terraform/templates/pipeline_workflow.json.tftpl
# for the actual orchestration logic -- this resource just deploys it.
#
# Gmail, not Office 365 Outlook -- the alert address
# (smuhammadhamza929@gmail.com) is a Gmail mailbox, and the Office 365
# connector can only ever authorize against a real Exchange/M365 mailbox,
# not a Gmail account. Needs a ONE-TIME manual "Authorize" click in the
# Azure Portal after the first apply (Logic Apps > API Connections > gmail
# > Edit API connection > Authorize), signing in with the Gmail account --
# not something Terraform or the CLI can complete non-interactively, since
# it's an OAuth consent flow. Directly analogous to the AWS project's SNS
# topic needing a one-time "confirm subscription" click in the alert
# email -- both are one-time human steps after infra exists, not ongoing
# manual toil.
resource "azurerm_api_connection" "gmail" {
  name                = "gmail"
  resource_group_name = var.resource_group_name
  managed_api_id      = data.azurerm_managed_api.gmail.id
  display_name        = "yt-pipeline-alerts"

  lifecycle {
    ignore_changes = [parameter_values] # authorization token gets written back by the portal's "Authorize" step
  }
}

data "azurerm_managed_api" "gmail" {
  name     = "gmail"
  location = var.location
}

resource "azurerm_logic_app_workflow" "this" {
  name                = "${var.project_name}-orchestration"
  resource_group_name = var.resource_group_name
  location            = var.location

  identity {
    type         = "UserAssigned"
    identity_ids = [var.logicapp_identity_id]
  }

  # A declared workflow_parameters entry with no default value blocks
  # CREATION of the workflow resource itself (validated even before any
  # definition/actions exist) -- confirmed against a real apply failure:
  # "the value for the workflow parameter '$connections' ... is not
  # provided". defaultValue: {} satisfies that check at create time; the
  # ARM template deployment below then overwrites it with the real
  # connection reference once the workflow (and the API connection it
  # points at) both exist.
  workflow_parameters = {
    "$connections" = jsonencode({ type = "Object", defaultValue = {} })
  }
}

resource "azurerm_resource_group_template_deployment" "workflow_definition" {
  name                = "${var.project_name}-workflow-def"
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"

  # The azurerm_logic_app_workflow resource itself doesn't have a first-class
  # argument for the full multi-action Workflow Definition Language JSON --
  # only azurerm_logic_app_trigger_recurrence / _action_* resources exist,
  # which would mean expressing every nested If/Until/Http action above as
  # a separate Terraform resource (fragile, verbose, and this workflow's
  # branching doesn't map cleanly onto those resource types). An ARM
  # template deployment that PATCHes the workflow's `definition` property
  # directly is the same pragmatic choice the AWS project made for
  # QuickSight's dashboard JSON: this is workflow content, not
  # infrastructure shape, and a raw template deploy iterates on it faster
  # than fighting Terraform's schema for it.
  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources = [
      {
        type       = "Microsoft.Logic/workflows"
        apiVersion = "2019-05-01"
        name       = azurerm_logic_app_workflow.this.name
        location   = var.location
        properties = {
          definition = jsondecode(var.workflow_definition_json)["definition"]
          parameters = {
            "$connections" = {
              value = {
                gmail = {
                  connectionId   = azurerm_api_connection.gmail.id
                  connectionName = azurerm_api_connection.gmail.name
                  id             = data.azurerm_managed_api.gmail.id
                }
              }
            }
          }
        }
      }
    ]
  })

  depends_on = [azurerm_logic_app_workflow.this]
}
