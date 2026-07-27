terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      # This env's resource group (HAMZA-RESOURCE-GROUP) is created once,
      # out of band, and referenced as a data source below -- Terraform
      # here manages what's INSIDE it, not the group itself, matching the
      # AWS project's bootstrap/prod split (bootstrap creates durable
      # account-level scaffolding by hand; prod's apply owns everything
      # that gets torn down/rebuilt).
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azuread" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}
