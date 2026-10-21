terraform {
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13.0"
    }

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

variable "workload_cluster_id" {
  type = string
}

variable "workload_cluster_location" {
  type = string
}


provider "azurerm" {
  features {}
  use_oidc = true
}

data "azurerm_client_config" "current" {}

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

// https://learn.microsoft.com/azure/templates/microsoft.containerservice/managedclusters/managednamespaces?pivots=deployment-language-terraform
resource "azapi_resource" "managed_namespace" {
  type      = "Microsoft.ContainerService/managedClusters/managedNamespaces@2026-03-02-preview"
  parent_id = var.workload_cluster_id
  location  = var.workload_cluster_location
  tags      = azurerm_resource_group.this.tags
  name      = var.team

  // this required when azapi local schema check isn't aware of the latest api version
  schema_validation_enabled = false

  body = {
    properties = {
      adoptionPolicy = "Always"
      annotations = {
        project = var.project
        owner   = var.team
      }
      defaultNetworkPolicy = {
        egress  = "AllowAll"
        ingress = "AllowAll"
      }
      defaultResourceQuota = {
        cpuLimit      = "2000m"
        cpuRequest    = "2000m"
        memoryLimit   = "4096Mi"
        memoryRequest = "4096Mi"
      }
      deletePolicy = "Delete"
      labels = {
        "headlamp.dev/project-id"            = var.team
        "headlamp.dev/project-managed-by"    = "aks-desktop"
        "aks-desktop/project-subscription"   = data.azurerm_client_config.current.subscription_id
        "aks-desktop/project-resource-group" = azurerm_resource_group.this.name
      }
    }
  }
}

resource "azurerm_role_assignment" "managed_namespace_user" {
  principal_id         = var.requester_object_id
  role_definition_name = "Azure Kubernetes Service Namespace User"
  scope                = azapi_resource.managed_namespace.id
}

resource "azurerm_role_assignment" "cluster_rbac_writer" {
  principal_id         = var.requester_object_id
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  scope                = var.workload_cluster_id
}

resource "azurerm_role_assignment" "cluster_user" {
  principal_id         = var.requester_object_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  scope                = var.workload_cluster_id
}

output "resource_group_id" {
  value = azurerm_resource_group.this.id
}

output "managed_namespace_id" {
  value = azapi_resource.managed_namespace.id
}