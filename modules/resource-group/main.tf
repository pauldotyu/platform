terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "requester_object_id" {
  type = string
}

provider "azurerm" {
  features {}
  use_oidc = true
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_role_assignment" "requester_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = var.requester_object_id
}

output "resource_group_id" {
  value = azurerm_resource_group.this.id
}
