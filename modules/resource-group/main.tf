terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

variable "team" {
  type = string
}

variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  type = string
}

variable "cost_center" {
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
  name     = "rg-${var.team}-${var.project}-${var.environment}"
  location = var.location
  tags = {
    team        = var.team
    project     = var.project
    environment = var.environment
    costCenter  = var.cost_center
  }
}

resource "azurerm_role_assignment" "requester_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Owner"
  principal_id         = var.requester_object_id
}

output "resource_group_id" {
  value = azurerm_resource_group.this.id
}
