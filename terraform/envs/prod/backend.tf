terraform {
  backend "azurerm" {
    resource_group_name  = "HAMZA-RESOURCE-GROUP"
    storage_account_name = "hamzatfstate72143"
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"
    use_azuread_auth     = true
  }
}
