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

# Request variables
variable "team" {
  type        = string
  description = "Requesting team. First segment of the namespace and resource group name."
  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.team)) && length(var.team) <= 20
    error_message = "team must be lowercase letters, digits, and single hyphens, at most 20 characters."
  }
}

variable "project" {
  type        = string
  description = "Project name. Second segment of the namespace and resource group name."
  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.project)) && length(var.project) <= 20
    error_message = "project must be lowercase letters, digits, and single hyphens, at most 20 characters."
  }
}

variable "environment" {
  type        = string
  description = "Environment name, for example dev or prod."
  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.environment)) && length(var.environment) <= 20
    error_message = "environment must be lowercase letters, digits, and single hyphens, at most 20 characters."
  }
}

variable "location" {
  type        = string
  description = "Azure region for the environment's resource group. Must match a region offered by the Backstage template."
  validation {
    condition     = contains(["westus3", "eastus", "centralus"], var.location)
    error_message = "location must be one of: westus3, eastus, centralus."
  }
}

variable "cost_center" {
  type        = string
  description = "Cost center tag applied to every resource."
  validation {
    condition     = can(regex("^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$", var.cost_center)) && length(var.cost_center) <= 20
    error_message = "cost_center must be letters, digits, and single hyphens, at most 20 characters."
  }
}

variable "requester_object_id" {
  type        = string
  description = "Entra object ID of the requester. Receives RG Owner, namespace, and model access."
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.requester_object_id)) && var.requester_object_id != "00000000-0000-0000-0000-000000000000"
    error_message = "requester_object_id must be a real Entra object ID, not the placeholder."
  }
}

# Platform variables
variable "workload_cluster_id" {
  type        = string
  description = "ID of the workload cluster."
  validation {
    condition     = can(regex("(?i)^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.ContainerService/managedClusters/[^/]+$", var.workload_cluster_id))
    error_message = "workload_cluster_id must be a valid Azure managed cluster resource ID."
  }
}

variable "shared_cluster_oidc_issuer_url" {
  type        = string
  description = "OIDC issuer URL of the shared cluster."
  validation {
    condition     = startswith(var.shared_cluster_oidc_issuer_url, "https://")
    error_message = "shared_cluster_oidc_issuer_url must be a valid URL."
  }
}

variable "shared_cluster_location" {
  type        = string
  description = "Location of the shared cluster."
}

variable "shared_monitor_workspace_id" {
  type        = string
  description = "Resource ID of the shared monitor workspace."
  validation {
    condition     = can(regex("(?i)/providers/Microsoft.Monitor/accounts/[^/]+$", var.shared_monitor_workspace_id))
    error_message = "shared_monitor_workspace_id must be a valid Azure resource ID."
  }
}

variable "shared_log_analytics_workspace_id" {
  type        = string
  description = "Resource ID of the shared Log Analytics workspace."
  validation {
    condition     = can(regex("(?i)/providers/Microsoft.OperationalInsights/workspaces/[^/]+$", var.shared_log_analytics_workspace_id))
    error_message = "shared_log_analytics_workspace_id must be a valid Azure resource ID."
  }
}

variable "shared_model_resource_id" {
  type        = string
  description = "Resource ID of the shared model."
  validation {
    condition     = can(regex("(?i)/providers/Microsoft.CognitiveServices/accounts/[^/]+$", var.shared_model_resource_id))
    error_message = "shared_model_resource_id must be a valid Azure resource ID."
  }
}

variable "shared_model_resource_name" {
  type        = string
  description = "Name of the shared model resource."
}

variable "extra_tags" {
  type        = map(string)
  description = "Platform-level tags, for example expiry or business unit. Request tags win on conflict."
  default     = {}
}

# Agents configuration
variable "agents" {
  type        = list(string)
  description = "Model-calling components. Each gets its own ServiceAccount, managed identity, federated credential, and model role."
  validation {
    condition     = length(var.agents) > 0 && length(var.agents) == length(distinct(var.agents)) && alltrue([for a in var.agents : can(regex("^[a-z]([a-z0-9-]{0,18}[a-z0-9])?$", a))])
    error_message = "agents must be a nonempty list of distinct lowercase DNS labels of at most 20 characters."
  }
  default = ["foundry"]
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
  namespace = "${var.team}-${var.project}-${var.environment}"
  # "foundry" keeps its original names so existing environments migrate without replacing the principal.
  identity_name = { for a in var.agents : a => a == "foundry" ? "mi-${local.namespace}" : "mi-${local.namespace}-${a}" }
  fic_name      = { for a in var.agents : a => a == "foundry" ? local.namespace : "${local.namespace}-${a}" }
  tags = merge(var.extra_tags, {
    team        = var.team
    project     = var.project
    environment = var.environment
    costCenter  = var.cost_center
    requestor   = var.requester_object_id
    managed-by  = "crossplane-opentofu"
    platform    = "agent-environment"
  })
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.namespace}"
  location = var.location
  tags     = local.tags
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

  tags = local.tags
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

  tags = local.tags

  lifecycle {
    precondition {
      condition     = !startswith(local.namespace, "kube-") && !contains(["default", "argocd", "crossplane-system", "agent-environments", "app-routing-system", "aks-istio-system", "gatekeeper-system", "cert-manager", "backstage"], local.namespace)
      error_message = "The namespace ${local.namespace} is reserved for the platform. Choose a different team, project, or environment."
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

resource "azurerm_user_assigned_identity" "agent" {
  for_each            = toset(var.agents)
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  name                = local.identity_name[each.key]
  tags                = merge(local.tags, { agent = each.key })
}

resource "azurerm_role_assignment" "agent_model_user" {
  for_each             = azurerm_user_assigned_identity.agent
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
  role_definition_name = "Cognitive Services OpenAI User"
  scope                = var.shared_model_resource_id
}

resource "azurerm_role_assignment" "requester_foundry_user" {
  principal_id         = var.requester_object_id
  role_definition_name = "Cognitive Services OpenAI User"
  scope                = var.shared_model_resource_id
}

resource "azurerm_federated_identity_credential" "agent" {
  for_each                  = azurerm_user_assigned_identity.agent
  user_assigned_identity_id = each.value.id
  name                      = "${var.team}-${var.project}-${var.environment}"
  issuer                    = var.shared_cluster_oidc_issuer_url
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "system:serviceaccount:${local.namespace}:${each.key}"
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

output "agent_client_ids" {
  description = "ServiceAccount name to managed identity client ID."
  value       = { for a, id in azurerm_user_assigned_identity.agent : a => id.client_id }
}

output "app_insights_resource_id" {
  value = azapi_resource.otel.id
}

output "app_insights_application_id" {
  description = "Application Insights AppId, sent as microsoft.applicationId on OTLP resource attributes."
  value       = azapi_resource.otel.output.properties.AppId
}