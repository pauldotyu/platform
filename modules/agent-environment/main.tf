terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.13.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.11.0"
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

variable "shared_cluster_oidc_issuer_url" {
  type = string
}

variable "shared_cluster_location" {
  type = string
}

variable "shared_monitor_workspace_id" {
  type = string
}

variable "shared_log_analytics_workspace_id" {
  type = string
}

variable "shared_model_resource_id" {
  type = string
}

variable "shared_model_resource_name" {
  type = string
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  use_oidc = true
}

data "azurerm_client_config" "current" {}

locals {
  namespace                    = "${var.team}-${var.project}-${var.environment}"
  foundry_service_account_name = "foundry"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.namespace}"
  location = var.location
  tags = {
    team        = var.team
    project     = var.project
    environment = var.environment
    costCenter  = var.cost_center
  }
}

resource "azapi_resource" "otel" {
  type      = "Microsoft.Insights/components@2025-01-23-preview"
  name      = "otel-${local.namespace}"
  parent_id = azurerm_resource_group.this.id
  location  = azurerm_resource_group.this.location

  schema_validation_enabled = false

  body = {
    kind = "web"
    properties = {
      ApplicationId                      = "otel-${local.namespace}"
      Application_Type                   = "web"
      Flow_Type                          = "Redfield"
      Request_Source                     = "IbizaAIExtension"
      IngestionMode                      = "LogAnalytics"
      WorkspaceResourceId                = var.shared_log_analytics_workspace_id
      AzureMonitorWorkspaceResourceId    = var.shared_monitor_workspace_id
      AzureMonitorWorkspaceIngestionMode = "Enabled"
      publicNetworkAccessForIngestion    = "Enabled"
      publicNetworkAccessForQuery        = "Enabled"
    }
  }

  response_export_values = [
    "*"
  ]
}

// https://learn.microsoft.com/azure/templates/microsoft.containerservice/managedclusters/managednamespaces?pivots=deployment-language-terraform
resource "azapi_resource" "namespace" {
  type      = "Microsoft.ContainerService/managedClusters/managedNamespaces@2026-03-02-preview"
  parent_id = var.workload_cluster_id
  location  = var.shared_cluster_location
  name      = local.namespace

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

resource "azurerm_role_assignment" "requester_resource_group_owner" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Owner"
  principal_id         = var.requester_object_id
}

resource "azurerm_role_assignment" "requester_namespace_user" {
  principal_id         = var.requester_object_id
  role_definition_name = "Azure Kubernetes Service Namespace User"
  scope                = azapi_resource.namespace.id
}

resource "azurerm_role_assignment" "requester_cluster_rbac_writer" {
  principal_id         = var.requester_object_id
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  scope                = var.workload_cluster_id
}

resource "azurerm_role_assignment" "requester_cluster_user" {
  principal_id         = var.requester_object_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  scope                = var.workload_cluster_id
}

resource "azurerm_user_assigned_identity" "foundry" {
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  name                = "mi-${var.team}-${var.project}-${var.environment}"
}

resource "azurerm_role_assignment" "requester_foundry_user" {
  principal_id         = var.requester_object_id
  role_definition_name = "Cognitive Services OpenAI User"
  scope                = var.shared_model_resource_id
}

resource "azurerm_role_assignment" "foundry_user" {
  principal_id         = azurerm_user_assigned_identity.foundry.principal_id
  role_definition_name = "Cognitive Services OpenAI User"
  scope                = var.shared_model_resource_id
}

resource "azurerm_federated_identity_credential" "foundry" {
  user_assigned_identity_id = azurerm_user_assigned_identity.foundry.id
  name                      = "${var.team}-${var.project}-${var.environment}"
  issuer                    = var.shared_cluster_oidc_issuer_url
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "system:serviceaccount:${var.team}-${var.project}-${var.environment}:${local.foundry_service_account_name}"
}

output "resource_group_id" {
  value = azurerm_resource_group.this.id
}

output "namespace_name" {
  value = azapi_resource.namespace.name
}

output "otel_logs_endpoint" {
  description = "The endpoint for OpenTelemetry logs"
  value       = azapi_resource.otel.output.properties.OTLPLogsEndpoint
}

output "otel_metrics_endpoint" {
  description = "The endpoint for OpenTelemetry metrics"
  value       = azapi_resource.otel.output.properties.OTLPMetricsEndpoint
}

output "otel_traces_endpoint" {
  description = "The endpoint for OpenTelemetry traces"
  value       = azapi_resource.otel.output.properties.OTLPTracesEndpoint
}

output "foundry_openai_base_url" {
  description = "The OpenAI v1 base URL for the Foundry account."
  value       = "https://${var.shared_model_resource_name}.services.ai.azure.com/openai/v1/"
}

output "foundry_service_account_name" {
  value = local.foundry_service_account_name
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.foundry.client_id
}
